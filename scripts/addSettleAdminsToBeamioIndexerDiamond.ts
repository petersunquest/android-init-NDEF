/**
 * 将 masterSetup.settle_contractAdmin[] 中的钱包地址添加到 BeamioIndexerDiamond 的 admin
 *
 * 用法:
 *   npx hardhat run scripts/addSettleAdminsToBeamioIndexerDiamond.ts --network conet
 *   DIAMOND_ADDRESS=0x... npx hardhat run scripts/addSettleAdminsToBeamioIndexerDiamond.ts --network conet
 *
 * 配置:
 *   - ~/.master.json 中的 settle_contractAdmin（私钥数组）
 *   - 若未设 DIAMOND_ADDRESS，则从 deployments/conet-IndexerDiamond.json 读取
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const CONET_RPC = "https://rpc1.conet.network";
const MASTER_PATH = path.join(homedir(), ".master.json");

const AdminFacetABI = [
  "function setAdmin(address admin, bool enabled) external",
  "function isAdmin(address admin) view returns (bool)",
  "function owner() view returns (address)",
];

function loadMasterSetup(): { settle_contractAdmin: string[] } {
  if (!fs.existsSync(MASTER_PATH)) {
    throw new Error("未找到 ~/.master.json，请配置 settle_contractAdmin");
  }
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  if (!data.settle_contractAdmin || !Array.isArray(data.settle_contractAdmin) || data.settle_contractAdmin.length === 0) {
    throw new Error("~/.master.json 中 settle_contractAdmin 为空或不是数组");
  }
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`)),
  };
}

function getDiamondAddress(): string {
  const env = process.env.DIAMOND_ADDRESS;
  if (env) return env;
  const deployPath = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
  if (!fs.existsSync(deployPath)) {
    throw new Error("未找到 deployments/conet-IndexerDiamond.json，请设置 DIAMOND_ADDRESS 环境变量");
  }
  const deploy = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  if (!deploy.diamond) throw new Error("deployments/conet-IndexerDiamond.json 中缺少 diamond 字段");
  return deploy.diamond;
}

async function main() {
  const master = loadMasterSetup();
  const diamondAddr = getDiamondAddress();

  const provider = new ethers.JsonRpcProvider(CONET_RPC);
  const signer = new ethers.Wallet(master.settle_contractAdmin[0], provider);

  const addresses = master.settle_contractAdmin.map((pk: string) => new ethers.Wallet(pk).address);

  console.log("=".repeat(60));
  console.log("添加 settle_contractAdmin 到 BeamioIndexerDiamond Admin");
  console.log("=".repeat(60));
  console.log("Diamond:", diamondAddr);
  console.log("RPC:", CONET_RPC);
  console.log("待添加地址数:", addresses.length);
  addresses.forEach((a, i) => console.log(`  ${i + 1}. ${a}`));
  console.log();

  const diamond = new ethers.Contract(diamondAddr, AdminFacetABI, signer);

  const owner = await diamond.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`当前 signer (${signer.address}) 不是 Diamond owner (${owner})，无法执行 setAdmin`);
  }

  for (let i = 0; i < addresses.length; i++) {
    const addr = addresses[i];
    const already = await diamond.isAdmin(addr);
    if (already) {
      console.log(`[${i + 1}/${addresses.length}] ${addr} 已是 admin，跳过`);
      continue;
    }
    const tx = await diamond.setAdmin(addr, true);
    console.log(`[${i + 1}/${addresses.length}] setAdmin(${addr}, true) tx: ${tx.hash}`);
    await tx.wait();
    console.log(`  ✅ 已添加`);
  }

  console.log("\n✅ 全部完成");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
