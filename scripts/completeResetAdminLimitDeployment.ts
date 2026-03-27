/**
 * 完成 resetAdminLimit 部署的剩余步骤（GovernanceModule 和 Factory 已部署）。
 * 设置 Factory 模块、Deployer.setFactory、更新配置。
 *
 * 运行：
 *   GOVERNANCE_MODULE=0x5c56536e833d0bfCC5BF575B3566edbE61987eAD \
 *   FACTORY=0x2EB245646de404b2Dce87E01C6282C131778bb05 \
 *   npx hardhat run scripts/completeResetAdminLimitDeployment.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function loadMasterSetup(): { settle_contractAdmin: string[] } {
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) throw new Error("未找到 ~/.master.json");
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  if (!data.settle_contractAdmin?.length) throw new Error("settle_contractAdmin 为空");
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`)),
  };
}

async function main() {
  const governanceModule = process.env.GOVERNANCE_MODULE || "0x5c56536e833d0bfCC5BF575B3566edbE61987eAD";
  const factoryAddress = process.env.FACTORY || "0x2EB245646de404b2Dce87E01C6282C131778bb05";

  const master = loadMasterSetup();
  const deployerPk = master.settle_contractAdmin[0];
  if (!deployerPk) throw new Error("settle_contractAdmin[0] 为空");

  const { ethers: hhEthers } = await networkModule.connect();
  const signer = new ethers.NonceManager(new ethers.Wallet(deployerPk, hhEthers.provider));

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const configPath = path.join(__dirname, "..", "config", "base-addresses.json");
  const existingFactoryPath = path.join(deploymentsDir, "base-UserCardFactory.json");

  if (!fs.existsSync(existingFactoryPath)) throw new Error("未找到 base-UserCardFactory.json");
  const data = JSON.parse(fs.readFileSync(existingFactoryPath, "utf-8"));
  const c = data.contracts?.beamioUserCardFactoryPaymaster;
  if (!c) throw new Error("缺少 beamioUserCardFactoryPaymaster 配置");

  const DEPLOYER_ADDRESS = data.contracts?.beamioUserCardDeployer?.address || c.deployer;
  const AA_FACTORY_ADDRESS = c.aaFactory || "0xD86403DD1755F7add19540489Ea10cdE876Cc1CE";
  const REDEEM_MODULE = c.redeemModule;
  const ISSUED_NFT_MODULE = c.issuedNftModule;
  const FAUCET_MODULE = c.faucetModule;
  const MEMBERSHIP_STATS_MODULE = c.membershipStatsModule;
  const ADMIN_STATS_QUERY_MODULE = c.adminStatsQueryModule;

  console.log("=".repeat(60));
  console.log("完成 resetAdminLimit 部署");
  console.log("=".repeat(60));
  console.log("GovernanceModule:", governanceModule);
  console.log("Factory:", factoryAddress);
  console.log("\n步骤 1: 设置 Factory 模块...");

  const factoryAbi = [
    "function setRedeemModule(address m) external",
    "function setIssuedNftModule(address m) external",
    "function setFaucetModule(address m) external",
    "function setGovernanceModule(address m) external",
    "function setMembershipStatsModule(address m) external",
    "function setAdminStatsQueryModule(address m) external",
  ];
  const factory = new hhEthers.Contract(factoryAddress, factoryAbi, signer);

  await (await factory.setRedeemModule(REDEEM_MODULE)).wait();
  if (ISSUED_NFT_MODULE && ISSUED_NFT_MODULE !== ethers.ZeroAddress)
    await (await factory.setIssuedNftModule(ISSUED_NFT_MODULE)).wait();
  if (FAUCET_MODULE && FAUCET_MODULE !== ethers.ZeroAddress)
    await (await factory.setFaucetModule(FAUCET_MODULE)).wait();
  await (await factory.setGovernanceModule(governanceModule)).wait();
  if (MEMBERSHIP_STATS_MODULE && MEMBERSHIP_STATS_MODULE !== ethers.ZeroAddress)
    await (await factory.setMembershipStatsModule(MEMBERSHIP_STATS_MODULE)).wait();
  if (ADMIN_STATS_QUERY_MODULE && ADMIN_STATS_QUERY_MODULE !== ethers.ZeroAddress)
    await (await factory.setAdminStatsQueryModule(ADMIN_STATS_QUERY_MODULE)).wait();
  console.log("  模块设置完成");

  console.log("\n步骤 2: Deployer.setFactory(新 Factory)...");
  const deployerContract = await hhEthers.getContractAt("BeamioUserCardDeployerV07", DEPLOYER_ADDRESS, signer);
  await (await deployerContract.setFactory(factoryAddress)).wait();
  console.log("  setFactory 成功");

  // 更新部署信息
  const deploymentInfo = {
    ...data,
    contracts: {
      ...data.contracts,
      beamioUserCardFactoryPaymaster: {
        address: factoryAddress,
        usdc: c.usdc,
        redeemModule: REDEEM_MODULE,
        quoteHelper: c.quoteHelper,
        deployer: DEPLOYER_ADDRESS,
        aaFactory: AA_FACTORY_ADDRESS,
        governanceModule,
        issuedNftModule: ISSUED_NFT_MODULE,
        faucetModule: FAUCET_MODULE,
        membershipStatsModule: MEMBERSHIP_STATS_MODULE,
        adminStatsQueryModule: ADMIN_STATS_QUERY_MODULE,
        metadataBaseURI: c.metadataBaseURI,
        owner: c.owner,
      },
    },
  };
  fs.writeFileSync(existingFactoryPath, JSON.stringify(deploymentInfo, null, 2));

  // 更新 config
  let baseJson: Record<string, unknown> = {};
  if (fs.existsSync(configPath)) baseJson = JSON.parse(fs.readFileSync(configPath, "utf-8"));
  baseJson.CARD_FACTORY = factoryAddress;
  fs.writeFileSync(configPath, JSON.stringify(baseJson, null, 2));

  // 更新 SilentPassUI
  const uiChainPath = path.join(__dirname, "..", "src", "SilentPassUI", "src", "config", "chainAddresses.ts");
  let BeamioCardCCSA = (baseJson as { CCSA_CARD_ADDRESS?: string }).CCSA_CARD_ADDRESS ?? "0x6700cA6ff47c75dcF7362aa64Ed9C56E1242b508";
  if (fs.existsSync(uiChainPath)) {
    const m = fs.readFileSync(uiChainPath, "utf-8").match(/BeamioCardCCSA_ADDRESS:\s*['"](0x[a-fA-F0-9]{40})['"]/);
    if (m) BeamioCardCCSA = m[1];
  }
  const uiContent = fs.readFileSync(uiChainPath, "utf-8").replace(
    /CARD_FACTORY:\s*['"][^'"]+['"]/,
    `CARD_FACTORY: '${factoryAddress}'`
  );
  fs.writeFileSync(uiChainPath, uiContent);

  // 更新 x402sdk
  const sdkChainPath = path.join(__dirname, "..", "src", "x402sdk", "src", "chainAddresses.ts");
  const sdkContent = fs.readFileSync(sdkChainPath, "utf-8").replace(
    /BASE_CARD_FACTORY\s*=\s*['"][^'"]+['"]/,
    `BASE_CARD_FACTORY = '${factoryAddress}'`
  );
  fs.writeFileSync(sdkChainPath, sdkContent);

  // 更新 Alliance
  const alliancePath = path.join(__dirname, "..", "src", "Alliance", "src", "config", "chainAddresses.ts");
  if (fs.existsSync(alliancePath)) {
    const allianceContent = fs.readFileSync(alliancePath, "utf-8").replace(
      /BASE_CARD_FACTORY\s*=\s*['"]0x[a-fA-F0-9]{40}['"]/,
      `BASE_CARD_FACTORY = '${factoryAddress}'`
    );
    fs.writeFileSync(alliancePath, allianceContent);
  }

  console.log("\n" + "=".repeat(60));
  console.log("完成");
  console.log("=".repeat(60));
  console.log("新 Factory:", factoryAddress);
  console.log("已更新 config、SilentPassUI、x402sdk、Alliance");
  console.log("\n请运行 npm run sync:card-artifact:full");
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
