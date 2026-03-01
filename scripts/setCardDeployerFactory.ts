/**
 * 为 BeamioUserCardDeployerV07 设置 factory 地址（Card Factory）。
 * 使用 Factory.deployer() 作为要设置的 Deployer（与 createCard 实际调用的合约一致）。
 *
 * 用法：npm run set:card-deployer-factory:base
 * 或：npx hardhat run scripts/setCardDeployerFactory.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  const networkInfo = await ethers.provider.getNetwork();
  const deploymentsDir = path.join(__dirname, "..", "deployments");

  const fullFile = path.join(deploymentsDir, "base-FullAccountAndUserCard.json");
  if (!fs.existsSync(fullFile)) {
    console.error("未找到 deployments/base-FullAccountAndUserCard.json");
    process.exit(1);
  }
  const data = JSON.parse(fs.readFileSync(fullFile, "utf-8"));
  const cardFactoryAddress = data.contracts?.beamioUserCardFactoryPaymaster?.address;
  if (!cardFactoryAddress) {
    console.error("部署文件中缺少 beamioUserCardFactoryPaymaster 地址");
    process.exit(1);
  }

  const factoryAbi = ["function deployer() view returns (address)"];
  const factory = new ethers.Contract(cardFactoryAddress, factoryAbi, ethers.provider);
  const userCardDeployerAddress = await factory.deployer();
  if (!userCardDeployerAddress || userCardDeployerAddress === ethers.ZeroAddress) {
    console.error("Card Factory.deployer() 未设置");
    process.exit(1);
  }

  const deployer = await ethers.getContractAt("BeamioUserCardDeployerV07", userCardDeployerAddress);
  const current = await deployer.factory();
  console.log("UserCard Deployer (Factory.deployer()):", userCardDeployerAddress);
  console.log("当前 Deployer.factory:", current);
  console.log("目标 Card Factory:", cardFactoryAddress);

  if (current.toLowerCase() === cardFactoryAddress.toLowerCase()) {
    console.log("已指向当前 Card Factory，无需操作");
    return;
  }

  console.log("调用 setFactory(Card Factory)...");
  const tx = await deployer.setFactory(cardFactoryAddress);
  await tx.wait();
  console.log("✅ 已设置，tx:", tx.hash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
