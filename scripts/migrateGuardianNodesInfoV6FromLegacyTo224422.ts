/**
 * 从源 RPC（默认 https://rpc1.conet.network / chain 224422）上的 GuardianNodesInfoV6 读取节点，
 * 在 224422（rpc1）目标合约上依次 addNode。
 *
 * 目标合约默认: 0xdE51f1daaCa6eae9BDeEe33E324c3e6e96837e94（须与线上 Guardian 一致）
 * 源合约地址不再写死在仓库：请设置 GUARDIAN_MIGRATE_SOURCE（须与 GUARDIAN_MIGRATE_SOURCE_RPC 为同一链）。
 *
 * 用法:
 *   GUARDIAN_MIGRATE_SOURCE=0x... DRY_RUN=1 npx hardhat run scripts/migrateGuardianNodesInfoV6FromLegacyTo224422.ts --network conet
 *
 * 环境变量:
 *   GUARDIAN_MIGRATE_SOURCE      必填：源链 GuardianNodesInfoV6 地址
 *   GUARDIAN_MIGRATE_SOURCE_RPC  默认 https://rpc1.conet.network
 *   GUARDIAN_MIGRATE_DEST        目标 GuardianNodesInfoV6，默认见下方常量
 *   PAGE_SIZE                    分页 getAllNodes 长度，默认 80
 *   DRY_RUN=1                    只拉取并打印，不发交易
 *   TX_DELAY_MS                  两笔交易间隔毫秒，默认 0
 */

import { network as hreNetwork } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const SOURCE_RPC_DEFAULT = "https://rpc1.conet.network";
const DEST_GUARDIAN_DEFAULT = "0xdE51f1daaCa6eae9BDeEe33E324c3e6e96837e94";

/** 与 GUARDIAN_MIGRATE_SOURCE_RPC 默认（rpc1）一致的 chainId */
const SOURCE_CHAIN_ID = 224422n;
/** rpc1 上 Conet 部署链 chainId */
const DEST_CHAIN_ID = 224422n;

function loadAbi(): unknown[] {
  const abiPath = path.join(__dirname, "..", "src", "mainnet", "abi", "GuardianNodesInfoV6.json");
  return JSON.parse(fs.readFileSync(abiPath, "utf-8")) as unknown[];
}

async function fetchAllNodes(
  src: import("ethers").Contract,
  pageSize: number
): Promise<
  { id: bigint; PGP: string; PGPKey: string; ip_addr: string; regionName: string }[]
> {
  const out: { id: bigint; PGP: string; PGPKey: string; ip_addr: string; regionName: string }[] = [];
  let start = 0;
  for (;;) {
    const page = await src.getAllNodes(start, pageSize);
    if (!page || page.length === 0) break;
    for (const row of page) {
      const id = row.id ?? row[0];
      const PGP = row.PGP ?? row[1];
      const PGPKey = row.PGPKey ?? row[2];
      const ip_addr = row.ip_addr ?? row[3];
      const regionName = row.regionName ?? row[4];
      out.push({
        id: BigInt(id.toString()),
        PGP: String(PGP ?? ""),
        PGPKey: String(PGPKey ?? ""),
        ip_addr: String(ip_addr ?? "").trim(),
        regionName: String(regionName ?? ""),
      });
    }
    if (page.length < pageSize) break;
    start += pageSize;
  }
  return out;
}

async function main() {
  const dry = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
  const pageSize = Math.max(1, parseInt(process.env.PAGE_SIZE || "80", 10) || 80);
  const txDelay = Math.max(0, parseInt(process.env.TX_DELAY_MS || "0", 10) || 0);

  const sourceAddr = (process.env.GUARDIAN_MIGRATE_SOURCE || "").trim();
  if (!sourceAddr) {
    throw new Error(
      "请设置 GUARDIAN_MIGRATE_SOURCE 为源 RPC（默认 rpc1）上的 GuardianNodesInfoV6 地址。"
    );
  }
  const destAddr = (process.env.GUARDIAN_MIGRATE_DEST || DEST_GUARDIAN_DEFAULT).trim();

  const abi = loadAbi();
  const { ethers } = await hreNetwork.connect();

  const sourceRpc = process.env.GUARDIAN_MIGRATE_SOURCE_RPC?.trim() || SOURCE_RPC_DEFAULT;
  const sourceProvider = new ethers.JsonRpcProvider(sourceRpc);
  const srcNet = await sourceProvider.getNetwork();
  if (srcNet.chainId !== SOURCE_CHAIN_ID) {
    console.warn(
      `警告: 源 RPC 链 ID 为 ${srcNet.chainId}，预期 ${SOURCE_CHAIN_ID}（默认 rpc1）。若继续可能读错合约。`
    );
  }

  const src = new ethers.Contract(sourceAddr, abi, sourceProvider);
  console.log("=".repeat(60));
  console.log("GuardianNodesInfoV6 迁移: 源 → 224422 新合约");
  console.log("=".repeat(60));
  console.log("源 RPC:", sourceRpc);
  console.log("源合约:", sourceAddr, "chainId", srcNet.chainId.toString());
  console.log("目标合约:", destAddr);
  console.log("DRY_RUN:", dry);
  console.log();

  const nodes = await fetchAllNodes(src, pageSize);
  console.log(`源链 getAllNodes 共 ${nodes.length} 条记录`);

  const rows: {
    id: bigint;
    PGP: string;
    PGPKey: string;
    ip_addr: string;
    regionName: string;
    owner: string;
  }[] = [];

  for (const n of nodes) {
    if (!n.ip_addr) {
      console.warn("跳过空 ip:", n);
      continue;
    }
    const owner: string = String(await src.ipaddress2owner(n.ip_addr));
    if (owner === ethers.ZeroAddress) {
      console.warn(`跳过（owner 为 0）: ip=${n.ip_addr} id=${n.id}`);
      continue;
    }
    rows.push({ ...n, owner });
  }

  console.log(`有效节点（含非零 owner）: ${rows.length}`);
  if (rows.length === 0) {
    console.log("无数据可迁移");
    return;
  }

  if (dry) {
    for (const r of rows) {
      console.log(
        `  id=${r.id} ip=${r.ip_addr} region=${r.regionName} owner=${r.owner} pgpLen=${r.PGP.length} keyLen=${r.PGPKey.length}`
      );
    }
    console.log("\nDRY_RUN: 未发送交易。去掉 DRY_RUN 后使用同一 hardhat conet 账户（须为目标合约 admin）执行。");
    return;
  }

  const [signer] = await ethers.getSigners();
  if (!signer) {
    throw new Error("hardhat 无可用签名账户：请在 ~/.master.json 配置 settle_contractAdmin / beamio_Admins 等私钥");
  }

  const destNet = await signer.provider!.getNetwork();
  if (destNet.chainId !== DEST_CHAIN_ID) {
    throw new Error(`目标链 ID 为 ${destNet.chainId}，预期 ${DEST_CHAIN_ID}（请使用 --network conet）`);
  }

  const dst = new ethers.Contract(destAddr, abi, signer);
  const isAdmin = await dst.adminList(signer.address);
  if (!isAdmin) {
    throw new Error(`签名地址 ${signer.address} 不是目标合约 admin（adminList 为 false）`);
  }
  console.log("签名账户:", signer.address, "余额:", ethers.formatEther(await signer.provider!.getBalance(signer.address)), "CNET");

  let ok = 0;
  let skipped = 0;
  for (const r of rows) {
    const exists = await dst.ipaddressExisting(r.ip_addr);
    if (exists) {
      console.log(`已存在，跳过: ${r.ip_addr}`);
      skipped++;
      continue;
    }
    const tx = await dst.addNode(r.id, r.ip_addr, r.regionName, r.PGP, r.PGPKey, r.owner);
    console.log(`addNode ${r.ip_addr} tx ${tx.hash}`);
    await tx.wait();
    ok++;
    if (txDelay > 0) await new Promise((res) => setTimeout(res, txDelay));
  }

  console.log("\n完成: 新写入", ok, "笔，跳过已存在", skipped, "笔");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
