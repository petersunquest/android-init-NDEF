/**
 * 从源 RPC 上的 GuardianNodesInfoV6 读取节点，在 224422（默认 https://rpc1.conet.network）目标合约上依次 addNode。
 *
 * 典型：旧链 224400 合约 0xCd68C3FFFE403f9F26081807c77aB29a4DF6940D → 新链 224422 合约
 * 0x920E09a09591587501D8bd34F15F807F6b2Dba90（以 deployments/conet-GuardianNodesInfoV6.json 为准）。
 *
 * 用法:
 *   GUARDIAN_MIGRATE_SOURCE=0xCd68C3FFFE403f9F26081807c77aB29a4DF6940D \
 *   GUARDIAN_MIGRATE_SOURCE_RPC=https://mainnet-rpc.conet.network \
 *   GUARDIAN_MIGRATE_EXPECT_SOURCE_CHAIN_ID=224400 \
 *   GUARDIAN_MIGRATE_DEST=0x920E09a09591587501D8bd34F15F807F6b2Dba90 \
 *   DRY_RUN=1 npx hardhat run scripts/migrateGuardianNodesInfoV6FromLegacyTo224422.ts --network conet
 *
 * 环境变量:
 *   GUARDIAN_MIGRATE_SOURCE      必填：源链 GuardianNodesInfoV6 地址
 *   GUARDIAN_MIGRATE_SOURCE_RPC  默认 https://rpc1.conet.network（跨链时请设为 224400 的 RPC，如 mainnet-rpc）
 *   GUARDIAN_MIGRATE_EXPECT_SOURCE_CHAIN_ID  若设置则必须与源 RPC chainId 一致，否则退出
 *   GUARDIAN_MIGRATE_DEST        目标合约；默认读 deployments/conet-GuardianNodesInfoV6.json
 *   GUARDIAN_MIGRATE_DUMP_PATH   若设置：拉取完成后将有效节点 JSON 写入该路径（DRY_RUN 或非 DRY_RUN 均可）
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
const DEPLOYMENT_GUARDIAN_PATH = path.join(
  __dirname,
  "..",
  "deployments",
  "conet-GuardianNodesInfoV6.json"
);

function loadDestGuardianDefault(): string {
  try {
    if (fs.existsSync(DEPLOYMENT_GUARDIAN_PATH)) {
      const j = JSON.parse(fs.readFileSync(DEPLOYMENT_GUARDIAN_PATH, "utf-8")) as {
        contracts?: { GuardianNodesInfoV6?: { address?: string } };
      };
      const a = j.contracts?.GuardianNodesInfoV6?.address?.trim();
      if (a) return a;
    }
  } catch {
    /* ignore */
  }
  return "0x920E09a09591587501D8bd34F15F807F6b2Dba90";
}

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
  const destAddr = (process.env.GUARDIAN_MIGRATE_DEST || loadDestGuardianDefault()).trim();

  const expectSrcChain = (process.env.GUARDIAN_MIGRATE_EXPECT_SOURCE_CHAIN_ID || "").trim();

  const abi = loadAbi();
  const { ethers } = await hreNetwork.connect();

  const sourceRpc = process.env.GUARDIAN_MIGRATE_SOURCE_RPC?.trim() || SOURCE_RPC_DEFAULT;
  const sourceProvider = new ethers.JsonRpcProvider(sourceRpc);
  const srcNet = await sourceProvider.getNetwork();
  if (expectSrcChain) {
    const want = BigInt(expectSrcChain);
    if (srcNet.chainId !== want) {
      throw new Error(
        `源 RPC chainId ${srcNet.chainId} 与 GUARDIAN_MIGRATE_EXPECT_SOURCE_CHAIN_ID=${expectSrcChain} 不一致`
      );
    }
  } else {
    console.log("源链 chainId:", srcNet.chainId.toString(), "（可用 GUARDIAN_MIGRATE_EXPECT_SOURCE_CHAIN_ID 强制校验）");
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
    let owner: string = String(await src.ipaddress2owner(n.ip_addr));
    if (owner === ethers.ZeroAddress) {
      owner = String(await src.idOwner(n.id));
    }
    if (owner === ethers.ZeroAddress) {
      console.warn(`跳过（ipaddress2owner 与 idOwner 均为 0）: ip=${n.ip_addr} id=${n.id}`);
      continue;
    }
    rows.push({ ...n, owner });
  }

  console.log(`有效节点（含非零 owner）: ${rows.length}`);
  if (rows.length === 0) {
    console.log("无数据可迁移");
    return;
  }

  const dumpPath = (process.env.GUARDIAN_MIGRATE_DUMP_PATH || "").trim();
  if (dumpPath) {
    fs.writeFileSync(
      dumpPath,
      JSON.stringify(
        rows.map((r) => ({
          id: r.id.toString(),
          ip_addr: r.ip_addr,
          regionName: r.regionName,
          owner: r.owner,
          PGP: r.PGP,
          PGPKey: r.PGPKey,
        })),
        null,
        2
      ),
      "utf-8"
    );
    console.log("已写入 GUARDIAN_MIGRATE_DUMP_PATH:", dumpPath);
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
