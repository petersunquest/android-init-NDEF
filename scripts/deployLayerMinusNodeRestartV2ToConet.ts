/**
 * 部署 src/mainnet/LayerMinusNodeRestart_V2.sol 到 CoNET (chainId 224422)。
 * 构造函数无参数；部署者自动成为 adminList[deployer] = true。
 *
 * 运行: npx hardhat run scripts/deployLayerMinusNodeRestartV2ToConet.ts --network conet
 *
 * JSON 验证（Blockscout v2）:
 *   node scripts/exportLayerMinusNodeRestartV2ConetStandardJson.mjs
 *   npx tsx scripts/verifyLayerMinusNodeRestartV2ConetStandardJson.ts
 *
 * 前置: ~/.master.json 中配置部署私钥（与 conet 网络一致），且账户有足够 native gas。
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

function mergeConetAddresses(contractAddr: string, deployer: string, txHash: string) {
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) {
    console.warn("  skip conet-addresses.json merge: file missing");
    return;
  }
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
  data.LayerMinusNodeRestart_V2 = contractAddr;
  data.layerMinusNodeRestartV2Deployer = deployer;
  data.layerMinusNodeRestartV2DeployedAt = new Date().toISOString();
  data.layerMinusNodeRestartV2Tx = txHash;
  fs.writeFileSync(addrPath, JSON.stringify(data, null, 2) + "\n", "utf-8");
  console.log("  merged LayerMinusNodeRestart_V2 into deployments/conet-addresses.json");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) {
    throw new Error("无签名账户：请配置 ~/.master.json（conet 网络）或 PRIVATE_KEY");
  }
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  console.log("=".repeat(60));
  console.log("Deploy LayerMinusNodeRestart_V2 on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "native");

  const Factory = await ethers.getContractFactory("LayerMinusNodeRestart_V2");
  const c = await Factory.deploy();
  await c.waitForDeployment();
  const address = await c.getAddress();
  const txHash = c.deploymentTransaction()?.hash ?? "";

  console.log("\n✅ LayerMinusNodeRestart_V2:", address);
  console.log("   tx:", txHash);

  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const outPath = path.join(deploymentsDir, "conet-LayerMinusNodeRestart_V2.json");
  const artifact = {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "LayerMinusNodeRestart_V2",
    source: "src/mainnet/LayerMinusNodeRestart_V2.sol",
    address,
    deployer: deployer.address,
    constructorArgs: [],
    timestamp: new Date().toISOString(),
    transactionHash: txHash,
  };
  fs.writeFileSync(outPath, JSON.stringify(artifact, null, 2) + "\n", "utf-8");
  console.log("saved:", outPath);

  mergeConetAddresses(address, deployer.address, txHash);

  console.log("\nExplorer: https://mainnet.conet.network/address/" + address);
  console.log("CoNET-SI: 将 localNodeCommand.ts 中 nodeRestartEvent_addr 更新为上述地址后可读取 restartBlockNumber。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
