/**
 * 完成 deployFullAccountAndUserCard 的步骤 7-9（当主脚本卡在验证时使用）
 * 使用已部署的合约地址完成：UserCard Factory → BeamioUserCard → setUserCard
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { deployBeamioUserCardLibraries, beamioUserCardFactoryLibraries } from "./beamioUserCardLibraries.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// 从终端输出获取的已部署地址（2026-02-13 部署）
const DEPLOYED = {
  accountDeployer: "0xC51858BcF81D0Ce05D51fAd080fCF034B187E753",
  beamioAccount: "0x7FA89BEf84D5047AD9883d6f4A53dE7A0D2815f2",
  containerModule: "0xF50e41dFB647F8a62F3DBAf8f3Fcb39d74C7c9C8",
  placeholder: "0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D",
  aaFactory: "0xD86403DD1755F7add19540489Ea10cdE876Cc1CE",
  redeemModule: "0x9566ce3B07d5DB5d8c63a93179A541C8b2f11448",
  userCardDeployer: "0x719DdE8C7917AF06cd66bB7e2118fa2F2eC81ED9",
};

const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const USER_CARD_URI = "https://beamio.app/api/metadata/0x";
const USER_CARD_CURRENCY = 4;
const USER_CARD_PRICE = "1000000";

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const networkInfo = await ethers.provider.getNetwork();
  const deploymentsDir = path.join(__dirname, "..", "deployments");

  console.log("完成部署步骤 7-9...");
  console.log("AA Factory:", DEPLOYED.aaFactory);

  // 7. BeamioUserCardFactoryPaymasterV07（可能已由主脚本部署）
  const userCardFactoryAddress = "0xb417B244D84b98CA37F5b4332c27d2ac90CD9DC7";
  console.log("✅ BeamioUserCardFactoryPaymasterV07:", userCardFactoryAddress);

  // setFactory on UserCardDeployer
  const deployerContract = await ethers.getContractAt("BeamioUserCardDeployerV07", DEPLOYED.userCardDeployer);
  const txSetFactory = await deployerContract.setFactory(userCardFactoryAddress);
  await txSetFactory.wait();
  console.log("✅ UserCardDeployer.setFactory 已调用");

  // 8. BeamioUserCard
  const cardLibs = await deployBeamioUserCardLibraries(ethers, deployer);
  const BeamioUserCardFactory = await ethers.getContractFactory("BeamioUserCard", beamioUserCardFactoryLibraries(cardLibs));
  const userCard = await BeamioUserCardFactory.deploy(
    USER_CARD_URI,
    USER_CARD_CURRENCY,
    USER_CARD_PRICE,
    deployer.address,
    DEPLOYED.aaFactory,
    0,
    false
  );
  await userCard.waitForDeployment();
  const userCardAddress = await userCard.getAddress();
  console.log("✅ BeamioUserCard (CCSA):", userCardAddress);

  // 9. AA Factory.setUserCard
  const aaFactory = await ethers.getContractAt("BeamioFactoryPaymasterV07", DEPLOYED.aaFactory);
  const txUC = await aaFactory.setUserCard(userCardAddress);
  await txUC.wait();
  console.log("✅ setUserCard 已调用");

  // 保存完整部署 JSON
  const out: Record<string, unknown> = {
    network: networkInfo.name,
    chainId: networkInfo.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    existing: {
      beamioOracle: "0xDa4AE8301262BdAaf1bb68EC91259E6C512A9A2B",
      beamioQuoteHelper: "0x50953EB5190ee7dabb0eA86a96364A540a834059",
    },
    contracts: {
      beamioAccountDeployer: { address: DEPLOYED.accountDeployer },
      beamioAccount: { address: DEPLOYED.beamioAccount },
      beamioContainerModule: { address: DEPLOYED.containerModule },
      beamioUserCardPlaceholder: { address: DEPLOYED.placeholder },
      beamioFactoryPaymaster: { address: DEPLOYED.aaFactory },
      redeemModule: { address: DEPLOYED.redeemModule },
      beamioUserCardDeployer: { address: DEPLOYED.userCardDeployer },
      beamioUserCardFactoryPaymaster: { address: userCardFactoryAddress },
      beamioUserCard: { address: userCardAddress },
    },
  };
  const outFile = path.join(deploymentsDir, `${networkInfo.name}-FullAccountAndUserCard.json`);
  fs.writeFileSync(outFile, JSON.stringify(out, null, 2));
  console.log("\n部署完成! 已保存:", outFile);
  console.log("\n📋 新地址:");
  console.log("  AA Factory:", DEPLOYED.aaFactory);
  console.log("  Card Factory:", userCardFactoryAddress);
  console.log("  BeamioUserCard (CCSA):", userCardAddress);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
