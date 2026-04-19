/**
 * 将旧链 224400 上 AddressPGP 已登记的 node route，按当前 224422 GuardianNodesInfoV6 的 IP，
 * 同步登记到新链 224422 的 AddressPGP（addRoutes 从 Guardian 读 pgpKey/owner，需 IP 在新 Guardian 中存在）。
 *
 * 224400 RPC: https://mainnet-rpc.conet.network
 * 224422 RPC: https://rpc1.conet.network
 *
 * 用法:
 *   DRY_RUN=1 npx tsx scripts/migrateAddressPGPRoutesFrom224400To224422.ts
 *   npx tsx scripts/migrateAddressPGPRoutesFrom224400To224422.ts
 *
 * 环境变量:
 *   LEGACY_RPC / NEW_RPC
 *   OLD_ADDRESS_PGP / NEW_ADDRESS_PGP / GUARDIAN_NEW
 *   ADDRESS_PGP_ADMIN_PK（非 DRY_RUN 时必填，或 ~/.master.json beamio_Admins）
 */

import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const LEGACY_RPC = process.env.LEGACY_RPC || "https://mainnet-rpc.conet.network";
const NEW_RPC = process.env.NEW_RPC || "https://rpc1.conet.network";
const OLD_ADDRESS_PGP = process.env.OLD_ADDRESS_PGP || "0x13A96Bcd6aB010619d1004A1Cb4f5FE149e0F4c4";
const NEW_ADDRESS_PGP =
  process.env.NEW_ADDRESS_PGP ||
  (() => {
    const p = path.join(__dirname, "..", "deployments", "conet-AddressPGP.json");
    if (fs.existsSync(p)) {
      const j = JSON.parse(fs.readFileSync(p, "utf-8")) as { AddressPGP?: string };
      if (j.AddressPGP) return j.AddressPGP;
    }
    return "0x9C94238945295146F3F572D77ae492C13DF90bDd";
  })();
const GUARDIAN_NEW = process.env.GUARDIAN_NEW || "0xdE51f1daaCa6eae9BDeEe33E324c3e6e96837e94";

const LEGACY_CHAIN = 224400n;
const NEW_CHAIN = 224422n;

const DRY_RUN = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
const BATCH_SIZE = Number(process.env.BATCH_SIZE || "40");

const GuardianABI = [
  "function getAllNodes(uint256 start, uint256 length) view returns (tuple(uint256 id, string PGP, string PGPKey, string ip_addr, string regionName)[])",
];
const AddressPGPABI = [
  "function addRoutes(string[] ipaddresses) external",
  "function nodeKeyExists(bytes32) view returns (bool)",
];

function keyHash(pgpKey: string): string {
  return ethers.keccak256(ethers.toUtf8Bytes(pgpKey));
}

function loadAdminPk(): string {
  const env = process.env.ADDRESS_PGP_ADMIN_PK;
  if (env) return env;
  const masterPath = path.join(process.env.HOME || "", ".master.json");
  if (fs.existsSync(masterPath)) {
    const d = JSON.parse(fs.readFileSync(masterPath, "utf-8"));
    const admins = d.beamio_Admins || d.settle_contractAdmin || [];
    if (admins[0]) return admins[0].startsWith("0x") ? admins[0] : `0x${admins[0]}`;
  }
  throw new Error("需设置 ADDRESS_PGP_ADMIN_PK 或 ~/.master.json 中 beamio_Admins/settle_contractAdmin");
}

async function main() {
  const legacyProvider = new ethers.JsonRpcProvider(LEGACY_RPC);
  const newProvider = new ethers.JsonRpcProvider(NEW_RPC);

  const [legacyId, newId] = await Promise.all([legacyProvider.getNetwork(), newProvider.getNetwork()]);
  if (legacyId.chainId !== LEGACY_CHAIN) {
    throw new Error(`LEGACY_RPC 期望 chainId ${LEGACY_CHAIN}，当前 ${legacyId.chainId}`);
  }
  if (newId.chainId !== NEW_CHAIN) {
    throw new Error(`NEW_RPC 期望 chainId ${NEW_CHAIN}，当前 ${newId.chainId}`);
  }

  const guardian = new ethers.Contract(GUARDIAN_NEW, GuardianABI, newProvider);
  const oldPgp = new ethers.Contract(OLD_ADDRESS_PGP, AddressPGPABI, legacyProvider);
  const newPgpRead = new ethers.Contract(NEW_ADDRESS_PGP, AddressPGPABI, newProvider);

  const nodes: { ip: string; pgpKey: string }[] = [];
  let start = 0;
  while (true) {
    const batch = await guardian.getAllNodes(start, 500);
    if (!batch?.length) break;
    for (const n of batch) {
      const ip = (n.ip_addr ?? n[3]) as string;
      const pgpKey = (n.PGPKey ?? n[2]) as string;
      if (ip && typeof ip === "string" && ip.trim() && pgpKey && typeof pgpKey === "string" && pgpKey.trim()) {
        nodes.push({ ip: ip.trim(), pgpKey: pgpKey.trim() });
      }
    }
    if (batch.length < 500) break;
    start += 500;
  }

  console.log("=".repeat(60));
  console.log("AddressPGP route 迁移: 224400 旧合约 → 224422 新合约");
  console.log("=".repeat(60));
  console.log("LEGACY_RPC:", LEGACY_RPC, "chain", LEGACY_CHAIN.toString());
  console.log("NEW_RPC:", NEW_RPC, "chain", NEW_CHAIN.toString());
  console.log("Guardian (224422):", GUARDIAN_NEW);
  console.log("旧 AddressPGP:", OLD_ADDRESS_PGP);
  console.log("新 AddressPGP:", NEW_ADDRESS_PGP);
  console.log("224422 Guardian 节点数(有 IP+PGPKey):", nodes.length);
  console.log("DRY_RUN:", DRY_RUN);
  console.log();

  const toAdd: string[] = [];
  const skipAlreadyNew: string[] = [];
  const skipNotOnOld: string[] = [];

  for (const { ip, pgpKey } of nodes) {
    const h = keyHash(pgpKey);
    const onOld = await oldPgp.nodeKeyExists(h);
    const onNew = await newPgpRead.nodeKeyExists(h);
    if (!onOld) {
      skipNotOnOld.push(ip);
      continue;
    }
    if (onNew) {
      skipAlreadyNew.push(ip);
      continue;
    }
    toAdd.push(ip);
  }

  console.log("旧合约曾登记 nodeKeyExists 且新链尚未登记:", toAdd.length);
  console.log("旧合约未登记（跳过）:", skipNotOnOld.length);
  console.log("新合约已存在（跳过）:", skipAlreadyNew.length);
  if (toAdd.length) {
    console.log("待登记 IP 列表:", JSON.stringify(toAdd));
  }

  if (DRY_RUN || toAdd.length === 0) {
    if (DRY_RUN && toAdd.length) console.log("\n[DRY_RUN] 未发送交易");
    return;
  }

  const signer = new ethers.Wallet(loadAdminPk(), newProvider);
  const newPgp = new ethers.Contract(NEW_ADDRESS_PGP, AddressPGPABI, signer);
  console.log("\nSigner:", signer.address);
  if (!(await newPgpRead.adminList(signer.address))) {
    throw new Error("Signer 不是新 AddressPGP 的 admin");
  }

  for (let i = 0; i < toAdd.length; i += BATCH_SIZE) {
    const chunk = toAdd.slice(i, i + BATCH_SIZE);
    const tx = await newPgp.addRoutes(chunk);
    console.log(`addRoutes(${chunk.length}) tx: ${tx.hash}`);
    await tx.wait();
    console.log("  ✅ confirmed");
  }
  console.log("\n完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
