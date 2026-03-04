/**
 * 重新部署 BeamioUserCardDeployerV07 与 BeamioUserCardFactoryPaymasterV07，
 * 并自动更新 config/base-addresses.ts、SilentPassUI、x402sdk、deployments。
 *
 * 使用 config/base-addresses.ts 中的 AA_FACTORY；RedeemModule/QuoteHelper 从 base-UserCardFactory.json 读取。
 *
 * 运行（Base 主网）：
 *   npx hardhat run scripts/redeployCardFactoryAndUpdateConfig.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { verifyContract } from "./utils/verifyContract.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const networkInfo = await ethers.provider.getNetwork();
  const chainId = Number(networkInfo.chainId);
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const configPath = path.join(__dirname, "..", "config", "base-addresses.ts");

  console.log("=".repeat(60));
  console.log("重新部署 Card Factory 并更新配置");
  console.log("=".repeat(60));
  console.log("部署账户:", deployer.address);
  console.log("网络:", networkInfo.name, "Chain ID:", chainId);
  console.log();

  if (chainId !== 8453) {
    console.log("⚠️  当前非 Base 主网 (8453)，请确认 USDC/AA_FACTORY 适用该链");
  }

  // AA_FACTORY：优先从 config 读取
  let AA_FACTORY_ADDRESS = process.env.AA_FACTORY_ADDRESS || "";
  if (!AA_FACTORY_ADDRESS && fs.existsSync(configPath)) {
    const config = fs.readFileSync(configPath, "utf-8");
    const m = config.match(/AA_FACTORY:\s*['"](0x[a-fA-F0-9]{40})['"]/);
    if (m) AA_FACTORY_ADDRESS = m[1];
  }
  if (!AA_FACTORY_ADDRESS) {
    AA_FACTORY_ADDRESS = "0xD86403DD1755F7add19540489Ea10cdE876Cc1CE";
  }
  console.log("使用 AA_FACTORY:", AA_FACTORY_ADDRESS);

  // RedeemModule、QuoteHelper：优先环境变量，否则从已有 base-UserCardFactory.json 读取
  let REDEEM_MODULE_ADDRESS = process.env.REDEEM_MODULE_ADDRESS || "";
  let QUOTE_HELPER_ADDRESS = process.env.QUOTE_HELPER_ADDRESS || "";

  const existingFactoryPath = path.join(deploymentsDir, "base-UserCardFactory.json");
  if (!REDEEM_MODULE_ADDRESS || !QUOTE_HELPER_ADDRESS) {
    if (fs.existsSync(existingFactoryPath)) {
      const data = JSON.parse(fs.readFileSync(existingFactoryPath, "utf-8"));
      const c = data.contracts?.beamioUserCardFactoryPaymaster;
      if (c) {
        if (!REDEEM_MODULE_ADDRESS && c.redeemModule) REDEEM_MODULE_ADDRESS = c.redeemModule;
        if (!QUOTE_HELPER_ADDRESS && c.quoteHelper) QUOTE_HELPER_ADDRESS = c.quoteHelper;
      }
    }
  }

  if (!REDEEM_MODULE_ADDRESS || !QUOTE_HELPER_ADDRESS) {
    throw new Error(
      "缺少 REDEEM_MODULE_ADDRESS 或 QUOTE_HELPER_ADDRESS。请设置环境变量或确保 deployments/base-UserCardFactory.json 存在且包含 redeemModule/quoteHelper。"
    );
  }

  const USDC_ADDRESS = process.env.USDC_ADDRESS || BASE_USDC;

  console.log("\n依赖地址:");
  console.log("  USDC:", USDC_ADDRESS);
  console.log("  RedeemModule:", REDEEM_MODULE_ADDRESS);
  console.log("  QuoteHelper:", QUOTE_HELPER_ADDRESS);
  console.log("  AA_FACTORY:", AA_FACTORY_ADDRESS);
  console.log("  Owner:", deployer.address);
  console.log();

  const checkCode = async (addr: string, name: string) => {
    const code = await ethers.provider.getCode(addr);
    if (code === "0x" || code === "0x0") throw new Error(`${name} 无合约代码: ${addr}`);
  };
  await checkCode(REDEEM_MODULE_ADDRESS, "RedeemModule");
  await checkCode(QUOTE_HELPER_ADDRESS, "QuoteHelper");
  await checkCode(AA_FACTORY_ADDRESS, "AA_FACTORY");

  // ---------- 1. 部署 BeamioUserCardDeployerV07 ----------
  console.log("步骤 1: 部署 BeamioUserCardDeployerV07...");
  const DeployerFactory = await ethers.getContractFactory("BeamioUserCardDeployerV07");
  const userCardDeployer = await DeployerFactory.deploy();
  await userCardDeployer.waitForDeployment();
  const deployerContractAddress = await userCardDeployer.getAddress();
  console.log("  BeamioUserCardDeployerV07:", deployerContractAddress);

  await new Promise((r) => setTimeout(r, 3000));
  await verifyContract(deployerContractAddress, [], "BeamioUserCardDeployerV07");

  // ---------- 2. 部署 BeamioUserCardFactoryPaymasterV07 ----------
  console.log("\n步骤 2: 部署 BeamioUserCardFactoryPaymasterV07...");
  const FactoryFactory = await ethers.getContractFactory("BeamioUserCardFactoryPaymasterV07");
  const factory = await FactoryFactory.deploy(
    USDC_ADDRESS,
    REDEEM_MODULE_ADDRESS,
    QUOTE_HELPER_ADDRESS,
    deployerContractAddress,
    AA_FACTORY_ADDRESS,
    deployer.address
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log("  BeamioUserCardFactoryPaymasterV07:", factoryAddress);

  await new Promise((r) => setTimeout(r, 5000));
  await verifyContract(
    factoryAddress,
    [
      USDC_ADDRESS,
      REDEEM_MODULE_ADDRESS,
      QUOTE_HELPER_ADDRESS,
      deployerContractAddress,
      AA_FACTORY_ADDRESS,
      deployer.address,
    ],
    "BeamioUserCardFactoryPaymasterV07"
  );

  // ---------- 3. Deployer 绑定 Factory ----------
  console.log("\n步骤 3: 调用 Deployer.setFactory(Factory)...");
  const tx = await userCardDeployer.setFactory(factoryAddress);
  await tx.wait();
  console.log("  setFactory 成功");

  // ---------- 4. 保存部署信息 ----------
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const deploymentInfo = {
    network: networkInfo.name,
    chainId: networkInfo.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      beamioUserCardDeployer: {
        address: deployerContractAddress,
        transactionHash: userCardDeployer.deploymentTransaction()?.hash,
      },
      beamioUserCardFactoryPaymaster: {
        address: factoryAddress,
        usdc: USDC_ADDRESS,
        redeemModule: REDEEM_MODULE_ADDRESS,
        quoteHelper: QUOTE_HELPER_ADDRESS,
        deployer: deployerContractAddress,
        aaFactory: AA_FACTORY_ADDRESS,
        owner: deployer.address,
        transactionHash: factory.deploymentTransaction()?.hash,
      },
    },
  };

  const outPath = path.join(deploymentsDir, `${networkInfo.name}-UserCardFactory.json`);
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\n4. 部署信息已保存:", outPath);

  // ---------- 5. 更新 config/base-addresses.ts（保留 AA_FACTORY，仅更新 CARD_FACTORY）----------
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
  console.log("5. 已更新 config/base-addresses.ts 的 CARD_FACTORY");

  // ---------- 6. 更新 src/SilentPassUI/src/config/chainAddresses.ts ----------
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
`;
  fs.writeFileSync(uiChainPath, uiChainContent);
  console.log("6. 已更新 src/SilentPassUI/src/config/chainAddresses.ts");

  // ---------- 7. 更新 src/x402sdk/src/chainAddresses.ts ----------
  const sdkChainPath = path.join(__dirname, "..", "src", "x402sdk", "src", "chainAddresses.ts");
  let BASE_CCSA_CARD = "0x6700cA6ff47c75dcF7362aa64Ed9C56E1242b508";
  if (fs.existsSync(sdkChainPath)) {
    const sdkCfg = fs.readFileSync(sdkChainPath, "utf-8");
    const m = sdkCfg.match(/BASE_CCSA_CARD_ADDRESS\s*=\s*['"](0x[a-fA-F0-9]{40})['"]/);
    if (m) BASE_CCSA_CARD = m[1];
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
 * Base 主网基础设施卡地址（BeamioUserCard 实例）。
 * 与服务端 getWalletAssets/getUIDAssets 的基础设施卡查询保持一致。
 */
export const BEAMIO_USER_CARD_ASSET_ADDRESS = '0xB7644DDb12656F4854dC746464af47D33C206F0E'

/**
 * CoNET BUnit Airdrop 合约地址（用于 claimBUnits）。
 */
export const CONET_BUNIT_AIRDROP_ADDRESS = '0x36dEc4b91ee3b9a0cF0F6f0df47955745Eae4a30'
`;
  fs.writeFileSync(sdkChainPath, sdkChainContent);
  console.log("7. 已更新 src/x402sdk/src/chainAddresses.ts");

  // ---------- 8. 更新 deployments/BASE_MAINNET_FACTORIES.md ----------
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

**重部署 Card Factory：** \`npm run redeploy:card-factory:base\`。自动更新 SilentPassUI、x402sdk、config。

---

## 区块浏览器

- AA Factory: https://basescan.org/address/${aaFactoryInConfig}
- Card Factory: https://basescan.org/address/${factoryAddress}

---

*Card Factory 重部署后请运行 \`npm run redeploy:card-factory:base\` 以自动更新所有配置。*
`;
  fs.writeFileSync(mdPath, mdContent);
  console.log("8. 已更新 deployments/BASE_MAINNET_FACTORIES.md");

  console.log("\n" + "=".repeat(60));
  console.log("部署与配置更新完成");
  console.log("=".repeat(60));
  console.log("\n新地址:");
  console.log("  BeamioUserCardDeployerV07:     ", deployerContractAddress);
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
