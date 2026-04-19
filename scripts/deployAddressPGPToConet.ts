/**
 * 部署 AddressPGP 到 CoNET mainnet
 * 需传入 GuardianNodesInfoV6 地址（0xdE51f1daaCa6eae9BDeEe33E324c3e6e96837e94）
 *
 * 运行: npx hardhat run scripts/deployAddressPGPToConet.ts --network conet
 * 或: GUARDIAN_NODES=0x... npx hardhat run scripts/deployAddressPGPToConet.ts --network conet
 */

import { network as hreNetwork } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const GUARDIAN_NODES_INFO_V6 = process.env.GUARDIAN_NODES || "0xdE51f1daaCa6eae9BDeEe33E324c3e6e96837e94";

async function main() {
  const { ethers } = await hreNetwork.connect();
  const [deployer] = await ethers.getSigners();

  console.log("=".repeat(60));
  console.log("部署 AddressPGP 到 CoNET mainnet");
  console.log("=".repeat(60));
  console.log("GuardianNodesInfoV6:", GUARDIAN_NODES_INFO_V6);
  console.log("部署账户:", deployer.address);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("余额:", ethers.formatEther(balance), "ETH");
  const net = await ethers.provider.getNetwork();
  console.log("网络:", net.name, "ChainId:", net.chainId.toString());

  if (balance === 0n) {
    throw new Error("账户余额为 0，无法部署");
  }

  console.log("\n[1] 部署 AddressPGP...");
  const AddressPGP = await ethers.getContractFactory("src/mainnet/AddressPGP.sol:AddressPGP");
  const contract = await AddressPGP.deploy(GUARDIAN_NODES_INFO_V6);
  await contract.waitForDeployment();
  const addr = await contract.getAddress();
  console.log("  AddressPGP:", addr);
  console.log("  部署账户已自动设为 admin");

  // 保存部署结果
  const deployDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deployDir)) fs.mkdirSync(deployDir, { recursive: true });
  const outPath = path.join(deployDir, "conet-AddressPGP.json");
  const result = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    guardianNodesInfoV6: GUARDIAN_NODES_INFO_V6,
    timestamp: new Date().toISOString(),
    AddressPGP: addr,
  };
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2));
  console.log("\n部署结果已保存至:", outPath);
  console.log("\n✅ 部署完成!");
  console.log("  AddressPGP 地址:", addr);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
