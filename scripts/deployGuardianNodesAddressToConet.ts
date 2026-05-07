/**
 * 部署 GuardianNodesAddress 到 CoNET mainnet
 * RPC: https://rpc1.conet.network
 * 使用 ~/.master.json settle_contractAdmin[0] 私钥
 *
 * 运行: npx hardhat run scripts/deployGuardianNodesAddressToConet.ts --network conet
 */

import { network as hreNetwork } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function main() {
  const { ethers } = await hreNetwork.connect();
  const [deployer] = await ethers.getSigners();

  console.log("=".repeat(60));
  console.log("部署 GuardianNodesAddress 到 CoNET mainnet");
  console.log("=".repeat(60));
  console.log("部署账户:", deployer.address);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("余额:", ethers.formatEther(balance), "ETH");
  const net = await ethers.provider.getNetwork();
  console.log("网络:", net.name, "ChainId:", net.chainId.toString());

  if (balance === 0n) {
    throw new Error("账户余额为 0，无法部署");
  }

  console.log("\n[1] 部署 GuardianNodesAddress...");
  const GuardianNodesAddress = await ethers.getContractFactory("GuardianNodesAddress");
  const contract = await GuardianNodesAddress.deploy();
  await contract.waitForDeployment();
  const addr = await contract.getAddress();
  console.log("  GuardianNodesAddress:", addr);
  console.log("  部署账户已自动设为 admin");

  // 保存部署结果
  const deployDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deployDir)) fs.mkdirSync(deployDir, { recursive: true });
  const outPath = path.join(deployDir, "conet-GuardianNodesAddress.json");
  const result = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    GuardianNodesAddress: addr,
  };
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2));
  console.log("\n部署结果已保存至:", outPath);
  console.log("\n✅ 部署完成!");
  console.log("  GuardianNodesAddress 地址:", addr);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
