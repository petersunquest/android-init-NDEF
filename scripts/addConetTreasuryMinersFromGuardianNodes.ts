/**
 * 查询 ConetTreasury 的 miner 数量与 requiredVotes（现已自动从 GuardianNodesInfoV6 获取）
 *
 * minerCount 自动从 GuardianNodesInfoV6.getUniqueOwnerCount() 获取，无需手动更新。
 * 本脚本用于诊断/验证当前状态。
 *
 * 运行: npx hardhat run scripts/addConetTreasuryMinersFromGuardianNodes.ts --network conet
 * 或: CONET_TREASURY=0x... npx hardhat run scripts/addConetTreasuryMinersFromGuardianNodes.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function getConetTreasuryAddress(): string {
  const env = process.env.CONET_TREASURY;
  if (env) return env;
  const deployPath = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
  if (fs.existsSync(deployPath)) {
    const d = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
    return d?.contracts?.ConetTreasury?.address || "";
  }
  throw new Error("未找到 ConetTreasury 地址，请设置 CONET_TREASURY 或确保 deployments/conet-ConetTreasury.json 存在");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const treasuryAddress = getConetTreasuryAddress();

  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddress);
  const guardianAddr = await treasury.guardianNodesInfoV6();

  console.log("=".repeat(60));
  console.log("ConetTreasury miner 状态（自动从 GuardianNodesInfoV6 获取）");
  console.log("=".repeat(60));
  console.log("ConetTreasury:", treasuryAddress);
  console.log("GuardianNodesInfoV6:", guardianAddr);

  if (guardianAddr === ethers.ZeroAddress) {
    console.log("\nGuardianNodesInfoV6 未设置，minerCount = 0");
    return;
  }

  const minerCount = await treasury.minerCount();
  const requiredVotes = await treasury.requiredVotes();

  console.log("\nminerCount:", minerCount.toString());
  console.log("requiredVotes:", requiredVotes.toString());
  console.log("\n（minerCount 现已自动从 GuardianNodesInfoV6.getUniqueOwnerCount() 获取，无需手动更新）");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
