/**
 * 从 CoNET gossip API（apiv4.conet.network/api/miningRate 的 nodeWallets[{ipAddr,wallet}]）拉取
 * 每个 DePIN 节点 IP 的真实运营钱包，并更新 GuardianNodesInfoV6 合约中各 guardian id 的
 * idOwner / ipaddress2owner（通过 admin 函数 id2node(address,uint256,string)）。
 *
 * 数据源（参照 src/CoNET-SI getAllNodeWallets / getAllNodes）：
 *   - 链上 getAllNodes(start,length) → 每个 guardian (id, ip_addr)
 *   - HTTP  POST https://apiv4.conet.network/api/miningRate?eposh=  → nodeWallets[{ipAddr,wallet}]
 *
 * 仅当链上 idOwner(id) 与 gossip 钱包不一致时才写入；id↔ip 绑定保持不变。
 *
 * 用法:
 *   DRY_RUN=1 npx hardhat run scripts/syncGuardianNodeOwnersFromGossip.ts --network conet   # 仅预览 diff
 *   npx hardhat run scripts/syncGuardianNodeOwnersFromGossip.ts --network conet              # 执行写入
 *
 * 环境变量:
 *   DRY_RUN=1        只打印 diff，不发交易
 *   TX_DELAY_MS      两笔交易间隔毫秒，默认 200
 *   GUARDIAN_ADDR    覆盖 GuardianNodesInfoV6 地址（默认下方常量）
 *   MINING_RATE_URL  覆盖 gossip URL（默认 apiv4）
 */

import { network } from "hardhat";
import https from "node:https";

const GUARDIAN_DEFAULT = "0xBC6b53065b5647261396d002bDBA0d3396E0722f";
const MINING_RATE_DEFAULT = "https://apiv4.conet.network/api/miningRate?eposh=";
const DEST_CHAIN_ID = 224422n;

const ABI = [
  "function getAllNodes(uint256 start, uint256 length) view returns (tuple(uint256 id,string PGP,string PGPKey,string ip_addr,string regionName)[])",
  "function idOwner(uint256) view returns (address)",
  "function ipaddress2owner(string) view returns (address)",
  "function adminList(address) view returns (bool)",
  "function id2node(address nodeAddress, uint256 id, string ipaddress)",
];

function postText(url: string, body: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      { host: u.host, path: u.pathname + u.search, port: 443, method: "POST", headers: { "Content-Type": "application/json;charset=UTF-8" } },
      (res) => {
        let d = "";
        res.on("data", (x) => (d += x));
        res.on("end", () => resolve(d));
      }
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

const normIp = (s: string) => String(s || "").trim().replace(/^::ffff:/i, "").toLowerCase();

async function main() {
  const { ethers } = await network.connect();
  const guardianAddr = (process.env.GUARDIAN_ADDR || GUARDIAN_DEFAULT).trim();
  const miningRateUrl = (process.env.MINING_RATE_URL || MINING_RATE_DEFAULT).trim();
  const dry = process.env.DRY_RUN === "1";
  const txDelay = Number(process.env.TX_DELAY_MS || "200");

  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("hardhat 无可用签名账户（~/.master.json）");
  const net = await signer.provider!.getNetwork();
  if (net.chainId !== DEST_CHAIN_ID) throw new Error(`目标链 ${net.chainId}，预期 ${DEST_CHAIN_ID}（--network conet）`);

  const c = new ethers.Contract(guardianAddr, ABI, signer);

  // 1) 链上全部 guardian 节点 (id, ip)
  const nodes: { id: bigint; ip: string }[] = [];
  for (let start = 0n; ; start += 100n) {
    const page = await c.getAllNodes(start, 100n);
    if (!page.length) break;
    for (const n of page) nodes.push({ id: n.id, ip: n.ip_addr });
  }
  console.log(`链上 guardian 节点: ${nodes.length}`);

  // 2) gossip IP → wallet
  const raw = await postText(miningRateUrl, "");
  let nw: { ipAddr: string; wallet: string }[] = [];
  try {
    nw = JSON.parse(raw)?.nodeWallets ?? [];
  } catch {
    throw new Error(`miningRate 解析失败: ${raw.slice(0, 200)}`);
  }
  if (!Array.isArray(nw) || nw.length === 0) throw new Error("miningRate 无 nodeWallets[]");
  const ipWallet = new Map<string, string>();
  for (const w of nw) {
    try {
      ipWallet.set(normIp(w.ipAddr), ethers.getAddress(w.wallet));
    } catch {
      /* skip bad wallet */
    }
  }
  console.log(`gossip nodeWallets: ${nw.length}`);

  // 3) 对账
  const toChange: { id: bigint; ip: string; from: string; to: string }[] = [];
  let match = 0;
  let noGossip = 0;
  for (const n of nodes) {
    const ip = normIp(n.ip);
    const gossip = ipWallet.get(ip);
    if (!gossip) {
      noGossip++;
      console.log(`  [no-gossip-wallet] id=${n.id} ip=${ip}`);
      continue;
    }
    const chainOwner = ethers.getAddress(await c.idOwner(n.id));
    if (chainOwner === gossip) match++;
    else toChange.push({ id: n.id, ip: n.ip, from: chainOwner, to: gossip });
  }

  console.log(`\nmatch=${match}  needChange=${toChange.length}  noGossip=${noGossip}`);
  for (const d of toChange) console.log(`  id=${d.id.toString().padStart(4)} ip=${normIp(d.ip).padEnd(16)} ${d.from} -> ${d.to}`);

  if (toChange.length === 0) {
    console.log("\n无需更新。");
    return;
  }
  if (dry) {
    console.log("\nDRY_RUN: 未发交易。去掉 DRY_RUN 执行写入。");
    return;
  }

  const isAdmin = await c.adminList(signer.address);
  if (!isAdmin) throw new Error(`签名地址 ${signer.address} 非 admin`);
  console.log(`\n签名: ${signer.address} 余额 ${ethers.formatEther(await signer.provider!.getBalance(signer.address))} CNET`);

  let ok = 0;
  for (const d of toChange) {
    const tx = await c.id2node(d.to, d.id, d.ip);
    console.log(`id2node id=${d.id} ip=${normIp(d.ip)} owner=${d.to} tx=${tx.hash}`);
    await tx.wait();
    ok++;
    if (txDelay > 0) await new Promise((r) => setTimeout(r, txDelay));
  }
  console.log(`\n完成: 更新 ${ok} 个 guardian id 的 owner 钱包。`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
