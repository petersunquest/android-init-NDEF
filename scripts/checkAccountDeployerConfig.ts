/**
 * 检查 BeamioAccountDeployer 与 AA Factory 的关联
 */
import { network as networkModule } from "hardhat";

const AA_FACTORY = "0x4b31D6a05Cdc817CAc1B06369555b37a5b182122";
const ACCOUNT_DEPLOYER = "0xC51858BcF81D0Ce05D51fAd080fCF034B187E753";

async function main() {
  const { ethers } = await networkModule.connect();

  const aaFactory = await ethers.getContractAt("BeamioFactoryPaymasterV07", AA_FACTORY);
  const deployerAddr = await aaFactory.deployer();
  console.log("AA Factory deployer():", deployerAddr);

  const accountDeployer = await ethers.getContractAt("BeamioAccountDeployer", deployerAddr);
  const deployerFactory = await accountDeployer.factory();
  console.log("AccountDeployer.factory():", deployerFactory);
  console.log("AA Factory 地址:", AA_FACTORY);
  console.log("匹配:", deployerFactory.toLowerCase() === AA_FACTORY.toLowerCase() ? "✅" : "❌");
}

main().catch(console.error);
