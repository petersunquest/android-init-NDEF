/**
 * 检查 createCard 所需链上配置：Deployer 是否指向 Card Factory。
 * 以 Factory.deployer() 为准（实际被调用的 Deployer），不依赖部署文件中的地址。
 * 若 createCardCollectionWithInitCode revert（missing revert data），通常是 Deployer 未配置。
 *
 * 运行：npx hardhat run scripts/checkCreateCardDeployerConfig.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  const { ethers } = await networkModule.connect();
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const fullPath = path.join(deploymentsDir, "base-FullAccountAndUserCard.json");

  if (!fs.existsSync(fullPath)) {
    console.error("未找到 deployments/base-FullAccountAndUserCard.json");
    process.exit(1);
  }

  const data = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
  const cardFactoryAddr = data.contracts?.beamioUserCardFactoryPaymaster?.address;
  const deployerFromFile = data.contracts?.beamioUserCardDeployer?.address;

  if (!cardFactoryAddr) {
    console.error("部署文件中缺少 beamioUserCardFactoryPaymaster");
    process.exit(1);
  }

  const factoryAbi = [
    "function deployer() view returns (address)",
    "function owner() view returns (address)",
  ];
  const deployerAbi = ["function factory() view returns (address)", "function owner() view returns (address)"];

  const factory = new ethers.Contract(cardFactoryAddr, factoryAbi, ethers.provider);
  const factoryDeployerAddr = await factory.deployer();
  if (!factoryDeployerAddr || factoryDeployerAddr === ethers.ZeroAddress) {
    console.error("Card Factory.deployer() 未设置");
    process.exit(1);
  }

  const deployer = new ethers.Contract(factoryDeployerAddr, deployerAbi, ethers.provider);
  const [deployerFactory, factoryOwner, deployerOwner, factoryCode, deployerCode] = await Promise.all([
    deployer.factory(),
    factory.owner(),
    deployer.owner(),
    ethers.provider.getCode(cardFactoryAddr),
    ethers.provider.getCode(factoryDeployerAddr),
  ]);

  console.log("========== createCard 链上配置检查 ==========");
  console.log("Card Factory:", cardFactoryAddr);
  console.log("  - owner:", factoryOwner);
  console.log("  - deployer():", factoryDeployerAddr, deployerFromFile && factoryDeployerAddr.toLowerCase() !== deployerFromFile.toLowerCase() ? "(与部署文件不一致)" : "");
  console.log("  - has code:", factoryCode !== "0x" && factoryCode.length > 2 ? "✅" : "❌");
  console.log();
  console.log("UserCard Deployer (Factory 实际使用):", factoryDeployerAddr);
  console.log("  - owner:", deployerOwner);
  console.log("  - factory():", deployerFactory);
  console.log("  - has code:", deployerCode !== "0x" && deployerCode.length > 2 ? "✅" : "❌");
  if (deployerFromFile && factoryDeployerAddr.toLowerCase() !== deployerFromFile.toLowerCase()) {
    console.log("  (部署文件中 beamioUserCardDeployer:", deployerFromFile + ")");
  }
  console.log();

  const deployerPointsToFactory =
    deployerFactory && cardFactoryAddr && deployerFactory.toLowerCase() === cardFactoryAddr.toLowerCase();

  if (!deployerPointsToFactory) {
    console.log("❌ Deployer.factory() 未指向 Card Factory");
    console.log("   → createCardCollectionWithInitCode 会 revert（DEP_NotFactory / missing revert data）");
    console.log();
    console.log("修复：由该 Deployer 的 owner 调用 setFactory(Card Factory)：");
    console.log("  npm run set:card-deployer-factory:base");
    console.log("  或：npx hardhat run scripts/setCardDeployerFactory.ts --network base");
    console.log();
    console.log("注意：需用 ~/.master.json 中 settle_contractAdmin 对应的钱包，且该钱包需为 Deployer.owner()");
    process.exit(1);
  }

  console.log("✅ Deployer 已正确指向 Card Factory");
  console.log("========== 检查完成 ==========");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
