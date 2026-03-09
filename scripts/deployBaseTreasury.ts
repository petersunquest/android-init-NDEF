/**
 * 使用 masterSetup.settle_contractAdmin[0] 部署 BaseTreasury 到 Base 主网
 * 部署者 (msg.sender) 自动成为首个 miner
 *
 * 运行: npx hardhat run scripts/deployBaseTreasury.ts --network base
 * 需在 ~/.master.json 中配置 settle_contractAdmin
 *
 * 部署完成后运行 Standard JSON 验证: npx tsx scripts/verifyBaseTreasuryStandardJson.ts
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function loadMasterSetup(): { settle_contractAdmin: string[]; base_endpoint?: string } {
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) {
    throw new Error("未找到 ~/.master.json，请配置 settle_contractAdmin");
  }
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  if (!data.settle_contractAdmin || !Array.isArray(data.settle_contractAdmin) || data.settle_contractAdmin.length === 0) {
    throw new Error("~/.master.json 中 settle_contractAdmin 为空或不是数组");
  }
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`)),
    base_endpoint: data.base_endpoint,
  };
}

async function main() {
  const master = loadMasterSetup();
  const deployerPk = master.settle_contractAdmin[0];
  if (!deployerPk) throw new Error("settle_contractAdmin[0] 为空");

  const { ethers } = await networkModule.connect();
  const baseRpc = master.base_endpoint || process.env.BASE_RPC_URL || "https://1rpc.io/base";
  const provider = new ethers.JsonRpcProvider(baseRpc);
  const deployer = new ethers.Wallet(deployerPk, provider);

  console.log("使用 settle_contractAdmin[0] 部署 BaseTreasury");
  console.log("部署账户:", deployer.address);
  console.log("账户余额:", ethers.formatEther(await provider.getBalance(deployer.address)), "ETH");

  console.log("\n部署 BaseTreasury...");

  const BaseTreasuryFactory = await ethers.getContractFactory("BaseTreasury");
  const treasury = await BaseTreasuryFactory.connect(deployer).deploy();

  await treasury.waitForDeployment();
  const address = await treasury.getAddress();

  console.log("✅ BaseTreasury 部署成功!");
  console.log("合约地址:", address);

  const networkInfo = await provider.getNetwork();
  const deploymentInfo = {
    network: networkInfo.name,
    chainId: networkInfo.chainId.toString(),
    contract: "BaseTreasury",
    address,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    transactionHash: treasury.deploymentTransaction()?.hash,
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const deploymentFile = path.join(deploymentsDir, `base-BaseTreasury.json`);
  fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));

  console.log("\n部署信息已保存到:", deploymentFile);
  console.log("\n下一步: 运行 Standard JSON 验证");
  console.log("  npx tsx scripts/verifyBaseTreasuryStandardJson.ts");
  console.log("\n查看合约: https://basescan.org/address/" + address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
