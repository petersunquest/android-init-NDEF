/**
 * 使用 masterSetup.settle_contractAdmin[0] 重新部署 BeamioUserCardFactoryPaymasterV07（仅 Factory，不部署 Deployer）。
 * 复用现有 Deployer、RedeemModule、QuoteHelper、AA_FACTORY。
 *
 * 运行（Base 主网）：
 *   npx hardhat run scripts/deployCardFactoryOnlyWithSettleAdmin.ts --network base
 *
 * 注意：settle_contractAdmin[0] 必须为现有 BeamioUserCardDeployerV07 的 owner，以便部署后调用 setFactory。
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
  const deployerWallet = new ethers.Wallet(deployerPk, ethers.provider);

  const networkInfo = await ethers.provider.getNetwork();
  const chainId = Number(networkInfo.chainId);
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const configPath = path.join(__dirname, "..", "config", "base-addresses.ts");

  console.log("=".repeat(60));
  console.log("使用 settle_contractAdmin[0] 部署 BeamioUserCardFactoryPaymasterV07");
  console.log("=".repeat(60));
  console.log("部署账户:", deployerWallet.address);
  console.log("网络:", networkInfo.name, "Chain ID:", chainId);
  console.log();

  if (chainId !== 8453) {
    console.log("⚠️  当前非 Base 主网 (8453)，请确认 USDC/AA_FACTORY 适用该链");
  }

  // 从 base-UserCardFactory.json 读取现有配置
  const existingFactoryPath = path.join(deploymentsDir, "base-UserCardFactory.json");
  if (!fs.existsSync(existingFactoryPath)) {
    throw new Error("未找到 deployments/base-UserCardFactory.json，请先运行 redeploy:card-factory:base 完整部署");
  }

  const data = JSON.parse(fs.readFileSync(existingFactoryPath, "utf-8"));
  const c = data.contracts?.beamioUserCardFactoryPaymaster;
  if (!c) throw new Error("base-UserCardFactory.json 缺少 beamioUserCardFactoryPaymaster 配置");

  const USDC_ADDRESS = process.env.USDC_ADDRESS || c.usdc || BASE_USDC;
  const REDEEM_MODULE_ADDRESS = process.env.REDEEM_MODULE_ADDRESS || c.redeemModule;
  const QUOTE_HELPER_ADDRESS = process.env.QUOTE_HELPER_ADDRESS || c.quoteHelper;
  const DEPLOYER_ADDRESS = process.env.DEPLOYER_ADDRESS || data.contracts?.beamioUserCardDeployer?.address || c.deployer;
  const AA_FACTORY_ADDRESS = process.env.AA_FACTORY_ADDRESS || c.aaFactory || "0x4b31D6a05Cdc817CAc1B06369555b37a5b182122";

  if (!REDEEM_MODULE_ADDRESS || !QUOTE_HELPER_ADDRESS || !DEPLOYER_ADDRESS) {
    throw new Error("缺少 RedeemModule、QuoteHelper 或 Deployer 地址");
  }

  console.log("依赖地址:");
  console.log("  USDC:", USDC_ADDRESS);
  console.log("  RedeemModule:", REDEEM_MODULE_ADDRESS);
  console.log("  QuoteHelper:", QUOTE_HELPER_ADDRESS);
  console.log("  Deployer:", DEPLOYER_ADDRESS);
  console.log("  AA_FACTORY:", AA_FACTORY_ADDRESS);
  console.log("  Owner:", deployerWallet.address);
  console.log();

  const checkCode = async (addr: string, name: string) => {
    const code = await ethers.provider.getCode(addr);
    if (code === "0x" || code === "0x0") throw new Error(`${name} 无合约代码: ${addr}`);
  };
  await checkCode(REDEEM_MODULE_ADDRESS, "RedeemModule");
  await checkCode(QUOTE_HELPER_ADDRESS, "QuoteHelper");
  await checkCode(DEPLOYER_ADDRESS, "Deployer");
  await checkCode(AA_FACTORY_ADDRESS, "AA_FACTORY");

  // ---------- 部署 BeamioUserCardFactoryPaymasterV07 ----------
  console.log("部署 BeamioUserCardFactoryPaymasterV07...");
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
  console.log("  BeamioUserCardFactoryPaymasterV07:", factoryAddress);

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

  // ---------- Deployer 绑定新 Factory ----------
  console.log("\n调用 Deployer.setFactory(新 Factory)...");
  const deployerContract = await ethers.getContractAt("BeamioUserCardDeployerV07", DEPLOYER_ADDRESS, deployerWallet);
  const setFactoryTx = await deployerContract.setFactory(factoryAddress);
  await setFactoryTx.wait();
  console.log("  setFactory 成功");

  // ---------- 保存部署信息 ----------
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

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
        metadataBaseURI: USER_CARD_METADATA_BASE_URI,
        owner: deployerWallet.address,
        transactionHash: factory.deploymentTransaction()?.hash,
      },
    },
  };

  fs.writeFileSync(existingFactoryPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\n部署信息已保存:", existingFactoryPath);

  // ---------- 更新 config/base-addresses.ts ----------
  let aaFactoryInConfig = AA_FACTORY_ADDRESS;
  if (fs.existsSync(configPath)) {
    const cfg = fs.readFileSync(configPath, "utf-8");
    const m = cfg.match(/AA_FACTORY:\s*['"](0x[a-fA-F0-9]{40})['"]/);
    if (m) aaFactoryInConfig = m[1];
  }

  const configContent = `/**
 * Base Mainnet 合约地址与链配置（供 SilentPassUI、SDK 等跨项目引用）
 * 与 deployments/BASE_MAINNET_FACTORIES.md 保持一致，请勿在 APP 中写死其他来源的地址。
 */
export const BASE_MAINNET_CHAIN_ID = 8453

export const BASE_MAINNET_FACTORIES = {
  /** AA 账户工厂 (BeamioFactoryPaymasterV07) */
  AA_FACTORY: '${aaFactoryInConfig}',
  /** UserCard 工厂 (BeamioUserCardFactoryPaymasterV07) */
  CARD_FACTORY: '${factoryAddress}',
} as const

/** 按链聚合，便于多链扩展 */
export const CONTRACT_ADDRESSES = {
  base: {
    chainId: BASE_MAINNET_CHAIN_ID,
    aaFactory: BASE_MAINNET_FACTORIES.AA_FACTORY,
    cardFactory: BASE_MAINNET_FACTORIES.CARD_FACTORY,
  },
} as const

export type ChainKey = keyof typeof CONTRACT_ADDRESSES
`;
  fs.writeFileSync(configPath, configContent);
  console.log("已更新 config/base-addresses.ts");

  // ---------- 更新 SilentPassUI chainAddresses.ts ----------
  const uiChainPath = path.join(__dirname, "..", "src", "SilentPassUI", "src", "config", "chainAddresses.ts");
  let BeamioCardCCSA = "0x6700cA6ff47c75dcF7362aa64Ed9C56E1242b508";
  if (fs.existsSync(uiChainPath)) {
    const uiCfg = fs.readFileSync(uiChainPath, "utf-8");
    const m = uiCfg.match(/BeamioCardCCSA_ADDRESS:\s*['"](0x[a-fA-F0-9]{40})['"]/);
    if (m) BeamioCardCCSA = m[1];
  }

  const uiChainContent = `/**
 * Base 主网合约地址（与项目根 config/base-addresses.ts 保持一致）。
 * 重部署 AA/Card Factory 后运行 npm run redeploy:card-factory:base 会同步更新根 config 与本文件。
 */
export const BASE_MAINNET_CHAIN_ID = 8453

export const BASE_MAINNET_FACTORIES = {
  /** AA 账户工厂 (BeamioFactoryPaymasterV07) */
  AA_FACTORY: '${aaFactoryInConfig}',
  /** UserCard 工厂 (BeamioUserCardFactoryPaymasterV07) */
  CARD_FACTORY: '${factoryAddress}',
  /** CCSA 卡 (BeamioUserCard 实例)。与 x402sdk chainAddresses.ts BASE_CCSA_CARD_ADDRESS 必须一致；重发卡后运行 replace-ccsa-address.js 同步两处 */
  BeamioCardCCSA_ADDRESS: '${BeamioCardCCSA}',
} as const

export const BASE_AA_FACTORY = BASE_MAINNET_FACTORIES.AA_FACTORY
export const BASE_CARD_FACTORY = BASE_MAINNET_FACTORIES.CARD_FACTORY
export const BASE_CCSA_CARD_ADDRESS = BASE_MAINNET_FACTORIES.BeamioCardCCSA_ADDRESS

/** Base 主网 BaseTreasury：USDC 购买 B-Unit。 */
export const BASE_TREASURY = '0x5c64a8b0935DA72d60933bBD8cD10579E1C40c58'
`;
  fs.writeFileSync(uiChainPath, uiChainContent);
  console.log("已更新 src/SilentPassUI/src/config/chainAddresses.ts");

  // ---------- 更新 x402sdk chainAddresses.ts ----------
  const sdkChainPath = path.join(__dirname, "..", "src", "x402sdk", "src", "chainAddresses.ts");
  let BASE_CCSA_CARD = "0x6700cA6ff47c75dcF7362aa64Ed9C56E1242b508";
  if (fs.existsSync(sdkChainPath)) {
    const sdkCfg = fs.readFileSync(sdkChainPath, "utf-8");
    const m = sdkCfg.match(/BASE_CCSA_CARD_ADDRESS\s*=\s*['"](0x[a-fA-F0-9]{40})['"]/);
    if (m) BASE_CCSA_CARD = m[1];
  }

  let CONET_BUNIT_AIRDROP = "0xbE1CF54f76BcAb40DC49cDcD7FBA525b9ABDa264";
  const conetAddrPath = path.join(deploymentsDir, "conet-addresses.json");
  if (fs.existsSync(conetAddrPath)) {
    const conetData = JSON.parse(fs.readFileSync(conetAddrPath, "utf-8"));
    if (conetData.BUnitAirdrop) CONET_BUNIT_AIRDROP = conetData.BUnitAirdrop;
  }

  const sdkChainContent = `/**
 * Base 主网 AA Factory 地址。
 * 与 config/base-addresses.ts 保持一致；运行 npm run redeploy:aa-factory:base 后会同步更新此处。
 */
export const BASE_AA_FACTORY = '${aaFactoryInConfig}'

/**
 * Base 主网 BeamioUserCard 工厂地址 (BeamioUserCardFactoryPaymasterV07)。
 * 与 config/base-addresses.ts 一致。
 */
export const BASE_CARD_FACTORY = '${factoryAddress}'

/**
 * Base 主网 CCSA 卡地址（BeamioUserCard 实例，1 CAD = 1 token）。
 * 与 SilentPassUI config/chainAddresses.ts BeamioCardCCSA_ADDRESS 必须一致；重发卡后运行 replace-ccsa-address.js 同步两处。
 */
export const BASE_CCSA_CARD_ADDRESS = '${BASE_CCSA_CARD}'

/**
 * Base 主网 BaseTreasury：USDC 购买 B-Unit，用户 EIP-3009 签字后由服务端提交 purchaseBUnitWith3009Authorization。
 */
export const BASE_TREASURY = '0x5c64a8b0935DA72d60933bBD8cD10579E1C40c58'

/**
 * Base 主网基础设施卡地址（BeamioUserCard 实例）。
 * 与服务端 getWalletAssets/getUIDAssets 的基础设施卡查询保持一致。
 */
export const BEAMIO_USER_CARD_ASSET_ADDRESS = '0xB7644DDb12656F4854dC746464af47D33C206F0E'

/**
 * 购买卡时用于获取 metadata 的发行卡地址（卡名、tiers 等展示信息从此卡获取）。
 */
export const PURCHASING_CARD_METADATA_ADDRESS = '0xf99018dffdb0c5657c93ca14db2900cebe1168a7'

/**
 * CoNET BUnit Airdrop 合约地址（用于 claimBUnits）。来自 deployments/conet-addresses.json
 */
export const CONET_BUNIT_AIRDROP_ADDRESS = '${CONET_BUNIT_AIRDROP}'

/**
 * CoNET 主网 MerchantPOSManagement 合约地址（商家 POS 终端登记/删除）。
 */
export const MERCHANT_POS_MANAGEMENT_CONET = '0x3Eb57035d3237Fce4b1cB273662E875EdfA0D54f'
`;
  fs.writeFileSync(sdkChainPath, sdkChainContent);
  console.log("已更新 src/x402sdk/src/chainAddresses.ts");

  // ---------- 更新 BASE_MAINNET_FACTORIES.md ----------
  const mdPath = path.join(deploymentsDir, "BASE_MAINNET_FACTORIES.md");
  const mdContent = `# Base Mainnet 基础设施地址

**单一数据源：** \`config/base-addresses.ts\`。AA/Card Factory 重部署后会更新该文件，UI/API/SDK 均从此处或同步文件读取。

---

## 1. AA Factory（账户工厂）

创建 BeamioAccount（智能合约账户）的工厂合约。  
重部署后地址会变，以 \`config/base-addresses.ts\` 中的 \`AA_FACTORY\` 为准。

| 项目 | 值 |
|------|-----|
| **合约** | BeamioFactoryPaymasterV07 |
| **地址** | 见 config/base-addresses.ts（当前为 \`${aaFactoryInConfig}\`） |
| **网络** | Base Mainnet (Chain ID: 8453) |

**重部署 AA Factory：** \`npm run redeploy:aa-factory:base\`。完成后需由 Card Factory owner 执行 \`npm run set:card-factory-aa:base\`（或链上调用 \`setAAFactory(新地址)\`）。

---

## 2. Card Factory（UserCard 工厂）

创建 BeamioUserCard（用户卡）的工厂合约。

| 项目 | 值 |
|------|-----|
| **合约** | BeamioUserCardFactoryPaymasterV07 |
| **地址** | 见 config/base-addresses.ts（当前为 \`${factoryAddress}\`） |
| **网络** | Base Mainnet (Chain ID: 8453) |

**重部署 Card Factory：** \`npm run redeploy:card-factory:base\` 或 \`npm run deploy:card-factory-only:base\`。自动更新 SilentPassUI、x402sdk、config。

---

## 区块浏览器

- AA Factory: https://basescan.org/address/${aaFactoryInConfig}
- Card Factory: https://basescan.org/address/${factoryAddress}

---

*Card Factory 重部署后请运行 \`npm run redeploy:card-factory:base\` 或 \`npm run deploy:card-factory-only:base\` 以自动更新所有配置。*
`;
  fs.writeFileSync(mdPath, mdContent);
  console.log("已更新 deployments/BASE_MAINNET_FACTORIES.md");

  console.log("\n" + "=".repeat(60));
  console.log("部署与配置更新完成");
  console.log("=".repeat(60));
  console.log("\n新地址:");
  console.log("  BeamioUserCardFactoryPaymasterV07:", factoryAddress);
  console.log("\n已更新:");
  console.log("  - config/base-addresses.ts");
  console.log("  - src/SilentPassUI/src/config/chainAddresses.ts");
  console.log("  - src/x402sdk/src/chainAddresses.ts");
  console.log("  - deployments/BASE_MAINNET_FACTORIES.md");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
