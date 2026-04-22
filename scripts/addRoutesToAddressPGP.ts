/**
 * 将 GuardianNodesInfoV6 中的节点同步到 AddressPGP 的 nodeKeyExists，使 regiestChatRoute 可用
 * addPublicPGPByAdmin 要求 routePgpKeyID 对应的节点既在 GuardianNodesInfoV6 中，也需在 AddressPGP 登记
 *
 * 用法: npx tsx scripts/addRoutesToAddressPGP.ts
 * 或: ADDRESS_PGP=0x... GUARDIAN_NODES=0x... npx tsx scripts/addRoutesToAddressPGP.ts
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONET_RPC = "https://rpc1.conet.network";
const GUARDIAN_NODES = process.env.GUARDIAN_NODES || "0x6d7a526BFD03E90ea8D19eDB986577395a139872";
const BATCH_SIZE = 50;

const GuardianNodesABI = [
  "function getAllNodes(uint256 start, uint256 length) view returns (tuple(uint256 id, string PGP, string PGPKey, string ip_addr, string regionName)[])",
];
const AddressPGPABI = [
  "function addRoutes(string[] ipaddresses) external",
  "function nodeKeyExists(bytes32) view returns (bool)",
];

function getAddressPGPAddress(): string {
  const env = process.env.ADDRESS_PGP;
  if (env) return env;
  const deployPath = path.join(__dirname, "..", "deployments", "conet-AddressPGP.json");
  if (fs.existsSync(deployPath)) {
    const d = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
    return d.AddressPGP || "";
  }
  return "0xb2aABe52f476356AE638839A786EAE425A0c1b66";
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
  const addressPGP = getAddressPGPAddress();
  const adminPk = loadAdminPk();
  const provider = new ethers.JsonRpcProvider(CONET_RPC);
  const signer = new ethers.Wallet(adminPk, provider);

  const guardian = new ethers.Contract(GUARDIAN_NODES, GuardianNodesABI, provider);
  const pgp = new ethers.Contract(addressPGP, AddressPGPABI, signer);

  console.log("=".repeat(60));
  console.log("同步 GuardianNodesInfoV6 节点到 AddressPGP");
  console.log("=".repeat(60));
  console.log("GuardianNodesInfoV6:", GUARDIAN_NODES);
  console.log("AddressPGP:", addressPGP);
  console.log("Signer:", signer.address);
  console.log();

  const allIps: string[] = [];
  let start = 0;
  while (true) {
    const nodes = await guardian.getAllNodes(start, 500);
    if (!nodes || nodes.length === 0) break;
    for (const n of nodes) {
      const ip = n.ip_addr || n[3];
      if (ip && typeof ip === "string" && ip.trim() !== "") allIps.push(ip.trim());
    }
    if (nodes.length < 500) break;
    start += 500;
  }
  console.log(`从 GuardianNodesInfoV6 获取到 ${allIps.length} 个 IP`);

  if (allIps.length === 0) {
    console.log("无节点可同步");
    return;
  }

  for (let i = 0; i < allIps.length; i += BATCH_SIZE) {
    const batch = allIps.slice(i, i + BATCH_SIZE);
    try {
      const tx = await pgp.addRoutes(batch);
      console.log(`[${i / BATCH_SIZE + 1}] addRoutes(${batch.length} IPs) tx: ${tx.hash}`);
      await tx.wait();
      console.log("  ✅ 已登记");
    } catch (e: any) {
      console.error(`  ❌ 失败: ${e?.message?.slice?.(0, 150) ?? e}`);
      for (const ip of batch) {
        try {
          const tx = await pgp.addRoutes([ip]);
          await tx.wait();
          console.log(`    单条 ${ip} 成功`);
        } catch (_) {}
      }
    }
  }
  console.log("\n完成");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
