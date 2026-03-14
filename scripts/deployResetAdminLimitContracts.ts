/**
 * 部署 resetAdminLimit 相关合约：新 GovernanceModule + 新 Factory，并更新所有引用。
 *
 * 改动：GovernanceModule（resetAdminLimit/resetAdminLimitByAdmin）、Factory（executeForAdmin 支持 RESET_ADMIN_LIMIT_SELECTOR）
 *
 * 运行（Base 主网）：
 *   npx hardhat run scripts/deployResetAdminLimitContracts.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { verifyContract } from "./utils/verifyContract.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

function loadMasterSetup(): { settle_contractAdmin: string[] } {
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
  };
}

async function main() {
  const master = loadMasterSetup();
  const deployerPk = master.settle_contractAdmin[0];
  if (!deployerPk) throw new Error("settle_contractAdmin[0] 为空");

  const { ethers } = await networkModule.connect();
  const deployerWallet = new ethers.Wallet(deployerPk, ethers.provider);

  const networkInfo = await ethers.provider.getNetwork();
  const chainId = Number(networkInfo.chainId);
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const configPath = path.join(__dirname, "..", "config", "base-addresses.json");

  console.log("=".repeat(60));
  console.log("部署 resetAdminLimit 相关合约（GovernanceModule + Factory）");
  console.log("=".repeat(60));
  console.log("部署账户:", deployerWallet.address);
  console.log("网络:", networkInfo.name, "Chain ID:", chainId);
  console.log();

  if (chainId !== 8453) {
    console.log("⚠️  当前非 Base 主网 (8453)");
  }

  const existingFactoryPath = path.join(deploymentsDir, "base-UserCardFactory.json");
  if (!fs.existsSync(existingFactoryPath)) {
    throw new Error("未找到 deployments/base-UserCardFactory.json");
  }

  const data = JSON.parse(fs.readFileSync(existingFactoryPath, "utf-8"));
  const c = data.contracts?.beamioUserCardFactoryPaymaster;
  if (!c) throw new Error("base-UserCardFactory.json 缺少 beamioUserCardFactoryPaymaster 配置");

  const USDC_ADDRESS = process.env.USDC_ADDRESS || c.usdc || BASE_USDC;
  const REDEEM_MODULE_ADDRESS = c.redeemModule;
  const QUOTE_HELPER_ADDRESS = c.quoteHelper;
  const DEPLOYER_ADDRESS = data.contracts?.beamioUserCardDeployer?.address || c.deployer;
  const AA_FACTORY_ADDRESS = c.aaFactory || "0xD86403DD1755F7add19540489Ea10cdE876Cc1CE";
  const ISSUED_NFT_MODULE = c.issuedNftModule;
  const FAUCET_MODULE = c.faucetModule;
  const MEMBERSHIP_STATS_MODULE = c.membershipStatsModule;
  const ADMIN_STATS_QUERY_MODULE = c.adminStatsQueryModule;

  if (!REDEEM_MODULE_ADDRESS || !QUOTE_HELPER_ADDRESS || !DEPLOYER_ADDRESS) {
    throw new Error("缺少 RedeemModule、QuoteHelper 或 Deployer 地址");
  }

  const checkCode = async (addr: string, name: string) => {
    const code = await ethers.provider.getCode(addr);
    if (code === "0x" || code === "0x0") throw new Error(`${name} 无合约代码: ${addr}`);
  };
  await checkCode(REDEEM_MODULE_ADDRESS, "RedeemModule");
  await checkCode(QUOTE_HELPER_ADDRESS, "QuoteHelper");
  await checkCode(DEPLOYER_ADDRESS, "Deployer");
  await checkCode(AA_FACTORY_ADDRESS, "AA_FACTORY");

  // ---------- 1. 部署新 GovernanceModule ----------
  console.log("步骤 1: 部署 BeamioUserCardGovernanceModuleV1...");
  const GovernanceFactory = await ethers.getContractFactory("BeamioUserCardGovernanceModuleV1");
  const governanceModule = await GovernanceFactory.connect(deployerWallet).deploy();
  await governanceModule.waitForDeployment();
  const newGovernanceModuleAddress = await governanceModule.getAddress();
  console.log("  新 GovernanceModule:", newGovernanceModuleAddress);

  await new Promise((r) => setTimeout(r, 3000));
  await verifyContract(newGovernanceModuleAddress, [], "BeamioUserCardGovernanceModuleV1");

  // ---------- 2. 部署新 Factory ----------
  console.log("\n步骤 2: 部署 BeamioUserCardFactoryPaymasterV07...");
  const USER_CARD_METADATA_BASE_URI = "https://beamio.app/api/metadata/0x";
  const FactoryFactory = await ethers.getContractFactory("BeamioUserCardFactoryPaymasterV07");
  const factory = await FactoryFactory.connect(deployerWallet).deploy(
    USDC_ADDRESS,
    REDEEM_MODULE_ADDRESS,
    QUOTE_HELPER_ADDRESS,
    DEPLOYER_ADDRESS,
    AA_FACTORY_ADDRESS,
    deployerWallet.address
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  await (await factory.setMetadataBaseURI(USER_CARD_METADATA_BASE_URI)).wait();
  console.log("  新 Factory:", factoryAddress);

  // ---------- 3. 设置新 Factory 的模块地址 ----------
  console.log("\n步骤 3: 设置 Factory 模块...");
  await (await factory.setRedeemModule(REDEEM_MODULE_ADDRESS)).wait();
  if (ISSUED_NFT_MODULE && ISSUED_NFT_MODULE !== ethers.ZeroAddress)
    await (await factory.setIssuedNftModule(ISSUED_NFT_MODULE)).wait();
  if (FAUCET_MODULE && FAUCET_MODULE !== ethers.ZeroAddress)
    await (await factory.setFaucetModule(FAUCET_MODULE)).wait();
  await (await factory.setGovernanceModule(newGovernanceModuleAddress)).wait();
  if (MEMBERSHIP_STATS_MODULE && MEMBERSHIP_STATS_MODULE !== ethers.ZeroAddress)
    await (await factory.setMembershipStatsModule(MEMBERSHIP_STATS_MODULE)).wait();
  if (ADMIN_STATS_QUERY_MODULE && ADMIN_STATS_QUERY_MODULE !== ethers.ZeroAddress)
    await (await factory.setAdminStatsQueryModule(ADMIN_STATS_QUERY_MODULE)).wait();
  console.log("  模块设置完成");

  await new Promise((r) => setTimeout(r, 5000));
  await verifyContract(
    factoryAddress,
    [
      USDC_ADDRESS,
      REDEEM_MODULE_ADDRESS,
      QUOTE_HELPER_ADDRESS,
      DEPLOYER_ADDRESS,
      AA_FACTORY_ADDRESS,
      deployerWallet.address,
    ],
    "BeamioUserCardFactoryPaymasterV07"
  );

  // ---------- 4. Deployer 绑定新 Factory ----------
  console.log("\n步骤 4: 调用 Deployer.setFactory(新 Factory)...");
  const deployerContract = await ethers.getContractAt("BeamioUserCardDeployerV07", DEPLOYER_ADDRESS, deployerWallet);
  const setFactoryTx = await deployerContract.setFactory(factoryAddress);
  await setFactoryTx.wait();
  console.log("  setFactory 成功");

  // ---------- 5. 保存部署信息 ----------
  const deploymentInfo = {
    network: networkInfo.name,
    chainId: networkInfo.chainId.toString(),
    deployer: deployerWallet.address,
    timestamp: new Date().toISOString(),
    contracts: {
      beamioUserCardDeployer: {
        address: DEPLOYER_ADDRESS,
        transactionHash: data.contracts?.beamioUserCardDeployer?.transactionHash,
      },
      beamioUserCardFactoryPaymaster: {
        address: factoryAddress,
        usdc: USDC_ADDRESS,
        redeemModule: REDEEM_MODULE_ADDRESS,
        quoteHelper: QUOTE_HELPER_ADDRESS,
        deployer: DEPLOYER_ADDRESS,
        aaFactory: AA_FACTORY_ADDRESS,
        governanceModule: newGovernanceModuleAddress,
        issuedNftModule: ISSUED_NFT_MODULE,
        faucetModule: FAUCET_MODULE,
        membershipStatsModule: MEMBERSHIP_STATS_MODULE,
        adminStatsQueryModule: ADMIN_STATS_QUERY_MODULE,
        metadataBaseURI: USER_CARD_METADATA_BASE_URI,
        owner: deployerWallet.address,
        transactionHash: factory.deploymentTransaction()?.hash,
      },
    },
  };

  fs.writeFileSync(existingFactoryPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\n部署信息已保存:", existingFactoryPath);

  // ---------- 6. 更新 config/base-addresses.json ----------
  let baseJson: Record<string, unknown> = {};
  if (fs.existsSync(configPath)) {
    baseJson = JSON.parse(fs.readFileSync(configPath, "utf-8"));
  }
  baseJson.CARD_FACTORY = factoryAddress;
  baseJson.AA_FACTORY = baseJson.AA_FACTORY ?? AA_FACTORY_ADDRESS;
  baseJson.BASE_MAINNET_CHAIN_ID = baseJson.BASE_MAINNET_CHAIN_ID ?? 8453;
  fs.writeFileSync(configPath, JSON.stringify(baseJson, null, 2));
  console.log("已更新 config/base-addresses.json");

  // ---------- 7. 更新 SilentPassUI chainAddresses.ts ----------
  const uiChainPath = path.join(__dirname, "..", "src", "SilentPassUI", "src", "config", "chainAddresses.ts");
  let BeamioCardCCSA = (baseJson as { CCSA_CARD_ADDRESS?: string }).CCSA_CARD_ADDRESS ?? "0x6700cA6ff47c75dcF7362aa64Ed9C56E1242b508";
  if (fs.existsSync(uiChainPath)) {
    const uiCfg = fs.readFileSync(uiChainPath, "utf-8");
    const m = uiCfg.match(/BeamioCardCCSA_ADDRESS:\s*['"](0x[a-fA-F0-9]{40})['"]/);
    if (m) BeamioCardCCSA = m[1];
  }

  const uiChainContent = `/**
 * Base 主网合约地址（与项目根 config/base-addresses.ts 保持一致）。
 * 重部署 AA/Card Factory 后运行部署脚本会同步更新根 config 与本文件。
 */
export const BASE_MAINNET_CHAIN_ID = 8453

export const BASE_MAINNET_FACTORIES = {
  AA_FACTORY: '${baseJson.AA_FACTORY ?? AA_FACTORY_ADDRESS}',
  CARD_FACTORY: '${factoryAddress}',
  BeamioCardCCSA_ADDRESS: '${BeamioCardCCSA}',
} as const

export const BASE_AA_FACTORY = BASE_MAINNET_FACTORIES.AA_FACTORY
export const BASE_CARD_FACTORY = BASE_MAINNET_FACTORIES.CARD_FACTORY
export const BASE_CCSA_CARD_ADDRESS = BASE_MAINNET_FACTORIES.BeamioCardCCSA_ADDRESS

export const BASE_TREASURY = '0x5c64a8b0935DA72d60933bBD8cD10579E1C40c58'
`;
  fs.writeFileSync(uiChainPath, uiChainContent);
  console.log("已更新 src/SilentPassUI/src/config/chainAddresses.ts");

  // ---------- 8. 更新 x402sdk chainAddresses.ts ----------
  const sdkChainPath = path.join(__dirname, "..", "src", "x402sdk", "src", "chainAddresses.ts");
  let BASE_CCSA_CARD = (baseJson as { CCSA_CARD_ADDRESS?: string }).CCSA_CARD_ADDRESS ?? "0x6700cA6ff47c75dcF7362aa64Ed9C56E1242b508";
  if (fs.existsSync(sdkChainPath)) {
    const sdkCfg = fs.readFileSync(sdkChainPath, "utf-8");
    const m = sdkCfg.match(/BASE_CCSA_CARD_ADDRESS\s*=\s*['"](0x[a-fA-F0-9]{40})['"]/);
    if (m) BASE_CCSA_CARD = m[1];
  }

  const conetAddrPath = path.join(deploymentsDir, "conet-addresses.json");
  let CONET_BUNIT_AIRDROP = "0xa7410a532544aB7d1bA70701D9D0E389e4f4Cc1F";
  if (fs.existsSync(conetAddrPath)) {
    const conetData = JSON.parse(fs.readFileSync(conetAddrPath, "utf-8"));
    if (conetData.BUnitAirdrop) CONET_BUNIT_AIRDROP = conetData.BUnitAirdrop;
  }

  const sdkChainContent = `/**
 * Base 主网 AA Factory 地址。
 */
export const BASE_AA_FACTORY = '${baseJson.AA_FACTORY ?? AA_FACTORY_ADDRESS}'

/**
 * Base 主网 BeamioUserCard 工厂地址 (BeamioUserCardFactoryPaymasterV07)。
 */
export const BASE_CARD_FACTORY = '${factoryAddress}'

/**
 * Base 主网 CCSA 卡地址。
 */
export const BASE_CCSA_CARD_ADDRESS = '${BASE_CCSA_CARD}'

export const BASE_TREASURY = '0x5c64a8b0935DA72d60933bBD8cD10579E1C40c58'

export const BEAMIO_USER_CARD_ASSET_ADDRESS = '${(baseJson as { BEAMIO_USER_CARD_ASSET_ADDRESS?: string }).BEAMIO_USER_CARD_ASSET_ADDRESS ?? "0xB7644DDb12656F4854dC746464af47D33C206F0E"}'

export const PURCHASING_CARD_METADATA_ADDRESS = '${(baseJson as { PURCHASING_CARD_METADATA_ADDRESS?: string }).PURCHASING_CARD_METADATA_ADDRESS ?? "0xf99018dffdb0c5657c93ca14db2900cebe1168a7"}'

export const CONET_BUNIT_AIRDROP_ADDRESS = '${CONET_BUNIT_AIRDROP}'

export const MERCHANT_POS_MANAGEMENT_CONET = '0x3Eb57035d3237Fce4b1cB273662E875EdfA0D54f'
`;
  fs.writeFileSync(sdkChainPath, sdkChainContent);
  console.log("已更新 src/x402sdk/src/chainAddresses.ts");

  // ---------- 9. 更新 Alliance chainAddresses.ts ----------
  const allianceChainPath = path.join(__dirname, "..", "src", "Alliance", "src", "config", "chainAddresses.ts");
  if (fs.existsSync(allianceChainPath)) {
    const allianceCfg = fs.readFileSync(allianceChainPath, "utf-8");
    const newAllianceCfg = allianceCfg.replace(
      /BASE_CARD_FACTORY\s*=\s*['"]0x[a-fA-F0-9]{40}['"]/,
      `BASE_CARD_FACTORY = '${factoryAddress}'`
    );
    fs.writeFileSync(allianceChainPath, newAllianceCfg);
    console.log("已更新 src/Alliance/src/config/chainAddresses.ts");
  }

  console.log("\n" + "=".repeat(60));
  console.log("部署与配置更新完成");
  console.log("=".repeat(60));
  console.log("\n新地址:");
  console.log("  GovernanceModule:", newGovernanceModuleAddress);
  console.log("  BeamioUserCardFactoryPaymasterV07:", factoryAddress);
  console.log("\n已更新:");
  console.log("  - config/base-addresses.json");
  console.log("  - src/SilentPassUI/src/config/chainAddresses.ts");
  console.log("  - src/x402sdk/src/chainAddresses.ts");
  console.log("  - src/Alliance/src/config/chainAddresses.ts");
  console.log("\n请运行 npm run sync:card-artifact:full 同步 Card ABI 到 x402sdk。");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
