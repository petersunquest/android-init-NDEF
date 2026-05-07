/**
 * 部署 BUint (B-Units ERC20) 到 CoNET mainnet
 * RPC: https://rpc1.conet.network
 *
 * 运行: npx hardhat run scripts/deployBUintToConet.ts --network conet
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
  console.log("Deploy BUint (B-Units) on CoNET mainnet");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("balance:", ethers.formatEther(balance), "CNET");

  const BUintFactory = await ethers.getContractFactory("BeamioBUnits");
  const buint = await BUintFactory.deploy();
  await buint.waitForDeployment();
  const buintAddress = await buint.getAddress();
  console.log("BUint deployed:", buintAddress);

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    initialOwner: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      BUint: {
        address: buintAddress,
        name: "B-Units",
        symbol: "BUNIT",
        decimals: 6,
        transactionHash: buint.deploymentTransaction()?.hash ?? "",
      },
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-BUint.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("saved:", outPath);

  const addressesPath = path.join(deploymentsDir, "conet-addresses.json");
  const addresses = fs.existsSync(addressesPath)
    ? JSON.parse(fs.readFileSync(addressesPath, "utf-8"))
    : { _comment: "CoNET mainnet 合约地址权威配置", network: "conet", chainId: net.chainId.toString() };
  addresses.network = "conet";
  addresses.chainId = net.chainId.toString();
  addresses.BUint = buintAddress;
  fs.writeFileSync(addressesPath, JSON.stringify(addresses, null, 2) + "\n", "utf-8");
  console.log("updated:", addressesPath, "BUint =", buintAddress);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
