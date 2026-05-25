/**
 * 部署 epoch_mining_info（mining_info.sol）到 CoNET mainnet，并将 epochManagre 加入 adminList。
 *
 * 运行: npx hardhat run scripts/deployConetEpochMiningInfoToCoet.ts --network conet
 *
 * 验证: npx tsx scripts/verifyConetEpochMiningInfoStandardJson.ts
 * 引用: npx tsx scripts/updateConetReferences.ts
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");
const MASTER_PATH = path.join(homedir(), ".master.json");
const ADDR_JSON = path.join(root, "deployments", "conet-addresses.json");

function loadEpochManagerAddress(ethers: typeof import("ethers")): string {
  if (!fs.existsSync(MASTER_PATH)) {
    throw new Error("未找到 ~/.master.json，无法解析 epochManagre");
  }
  const raw = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8")) as { epochManagre?: string };
  const pk = raw.epochManagre?.trim();
  if (!pk) throw new Error("~/.master.json 缺少 epochManagre 私钥");
  const wallet = new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`);
  return wallet.address;
}

function mergeConetAddresses(patch: Record<string, string>): void {
  if (!fs.existsSync(ADDR_JSON)) return;
  const data = JSON.parse(fs.readFileSync(ADDR_JSON, "utf-8")) as Record<string, unknown>;
  Object.assign(data, patch);
  fs.writeFileSync(ADDR_JSON, JSON.stringify(data, null, 2) + "\n", "utf-8");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户：请配置 ~/.master.json 或 PRIVATE_KEY");

  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);

  const epochManagerAddr = loadEpochManagerAddress(ethers);

  console.log("=".repeat(60));
  console.log("Deploy epoch_mining_info on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log(
    "balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "native"
  );
  console.log("epochManagre (will grant admin):", epochManagerAddr);

  const Factory = await ethers.getContractFactory("epoch_mining_info");
  const sc = await Factory.deploy();
  await sc.waitForDeployment();
  const addr = await sc.getAddress();
  const deployTx = sc.deploymentTransaction()?.hash ?? "";
  console.log("\n✅ epoch_mining_info:", addr);
  console.log("   tx:", deployTx);

  const isDeployerAdmin = await sc.adminList(deployer.address);
  console.log("deployer adminList:", isDeployerAdmin);

  if (epochManagerAddr.toLowerCase() !== deployer.address.toLowerCase()) {
    const txAdmin = await sc.changeAddressInAdminlist(epochManagerAddr, true);
    await txAdmin.wait();
    console.log("✅ changeAddressInAdminlist(epochManagre, true):", txAdmin.hash);
  } else {
    console.log("epochManagre 与 deployer 相同，跳过 admin 授权");
  }

  const epochManagerIsAdmin = await sc.adminList(epochManagerAddr);
  if (!epochManagerIsAdmin) throw new Error("epochManagre 未成功加入 adminList");

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "epoch_mining_info",
    source: "src/b-unit/mining_info.sol",
    address: addr,
    deployer: deployer.address,
    epochManager: epochManagerAddr,
    constructorArgs: [],
    timestamp: new Date().toISOString(),
    transactionHash: deployTx,
  };

  const depPath = path.join(root, "deployments", "conet-epoch_mining_info.json");
  fs.writeFileSync(depPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("saved:", depPath);

  mergeConetAddresses({ EpochMiningInfo: addr });
  console.log("updated conet-addresses.json EpochMiningInfo:", addr);
  console.log("\nExplorer:", `https://mainnet.conet.network/address/${addr}`);
  console.log("验证: npx tsx scripts/verifyConetEpochMiningInfoStandardJson.ts");
  console.log("引用: npx tsx scripts/updateConetReferences.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
