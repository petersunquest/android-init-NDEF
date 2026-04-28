/**
 * 部署 MerchantPOSManagement 到 CoNET mainnet
 * RPC: https://rpc1.conet.network
 *
 * 运行: npx hardhat run scripts/deployMerchantPOSManagementToConet.ts --network conet
 *
 * 前置: 确保 ~/.master.json 中 settle_contractAdmin[0] 为部署者私钥，
 *       部署者需有足够 CNET 支付 gas。
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("Deploy MerchantPOSManagement on CoNET mainnet");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("balance:", ethers.formatEther(balance), "CNET");

  const MerchantPOSManagementFactory = await ethers.getContractFactory("MerchantPOSManagement");
  const contract = await MerchantPOSManagementFactory.deploy();
  await contract.waitForDeployment();
  const contractAddress = await contract.getAddress();
  console.log("MerchantPOSManagement deployed:", contractAddress);

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      MerchantPOSManagement: {
        address: contractAddress,
        transactionHash: contract.deploymentTransaction()?.hash ?? "",
      },
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-MerchantPOSManagement.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("saved:", outPath);
  console.log("\nExplorer: https://mainnet.conet.network/address/" + contractAddress);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
