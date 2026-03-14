/**
 * 重新部署 AA Factory（含修复后的 BeamioAccount 逻辑），并更新 config、Card Factory 依赖。
 *
 * 步骤：
 * 1. 部署新的 BeamioAccountDeployer
 * 2. 从 base-FactoryAndModule.json 读取 containerModule / quoteHelper / userCard / usdc
 * 3. 部署新的 BeamioFactoryPaymasterV07（字节码内含修复后的 BeamioAccount）
 * 4. 调用 newDeployer.setFactory(newFactoryAddress)
 * 5. 写回 deployments/base-FactoryAndModule.json
 * 6. 更新 config/base-addresses.ts 中的 AA_FACTORY
 * 7. 若设置了 CARD_FACTORY_ADDRESS 且 CARD_FACTORY_OWNER_PK 存在，则调用 setAAFactory
 *
 * 用法：
 *   npx hardhat run scripts/redeployAAFactoryAndUpdateConfig.ts --network base
 *
 * 可选环境变量：
 *   CARD_FACTORY_ADDRESS   - Card Factory 地址（默认从 config 读）
 *   CARD_FACTORY_OWNER_PK - Card Factory owner 私钥，用于调用 setAAFactory
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { verifyContract } from "./utils/verifyContract.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const CONFIG_PATH = path.join(__dirname, "..", "config", "base-addresses.ts");
const DEPLOYMENTS_DIR = path.join(__dirname, "..", "deployments");
const DEPLOYMENT_FILE = path.join(DEPLOYMENTS_DIR, "base-FactoryAndModule.json");
const FULL_ACCOUNT_FILE = path.join(DEPLOYMENTS_DIR, "base-FullAccountAndUserCard.json");

/** 当前 Base 主网 Card Factory，写入 config 时保持不改；与 config/base-addresses.ts 一致 */
function getCardFactoryForConfig(): string {
  if (process.env.CARD_FACTORY_ADDRESS) return process.env.CARD_FACTORY_ADDRESS;
  if (fs.existsSync(FULL_ACCOUNT_FILE)) {
    const data = JSON.parse(fs.readFileSync(FULL_ACCOUNT_FILE, "utf-8"));
    const addr = data.contracts?.beamioUserCardFactoryPaymaster?.address;
    if (addr) return addr;
  }
  if (fs.existsSync(CONFIG_PATH)) {
    const content = fs.readFileSync(CONFIG_PATH, "utf-8");
    const m = content.match(/CARD_FACTORY:\s*['"](0x[a-fA-F0-9]{40})['"]/);
    if (m) return m[1];
  }
  return "0x2F45f38f2B6EF97b606ec2557E237529e8db9281";
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  const networkInfo = await ethers.provider.getNetwork();
  const networkName = networkInfo.name;

  if (networkName !== "base") {
    console.warn("⚠️  本脚本面向 Base 主网。当前网络:", networkName);
  }

  console.log("=".repeat(60));
  console.log("重新部署 AA Factory 并更新配置");
  console.log("=".repeat(60));
  console.log("网络:", networkName);
  console.log("部署账户:", signer.address);
  console.log("余额:", ethers.formatEther(await ethers.provider.getBalance(signer.address)), "ETH\n");

  // 读取现有依赖（Base）
  if (!fs.existsSync(DEPLOYMENT_FILE)) {
    throw new Error(`缺少部署文件: ${DEPLOYMENT_FILE}，请先部署 Factory 或提供依赖地址`);
  }
  const existing = JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf-8"));
  const oldFactory = existing.contracts?.beamioFactoryPaymaster;
  const CONTAINER_MODULE_ADDRESS =
    process.env.CONTAINER_MODULE_ADDRESS || existing.contracts?.beamioContainerModule?.address;
  const QUOTE_HELPER_ADDRESS =
    process.env.QUOTE_HELPER_ADDRESS || oldFactory?.quoteHelper;
  const USER_CARD_ADDRESS = process.env.USER_CARD_ADDRESS || oldFactory?.userCard;
  const chainId = Number(networkInfo.chainId);
  const USDC_ADDRESS =
    process.env.USDC_ADDRESS ||
    (chainId === 8453
      ? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
      : "0x036CbD53842c5426634e7929541eC2318f3dCF7e");
  const INITIAL_ACCOUNT_LIMIT = parseInt(process.env.INITIAL_ACCOUNT_LIMIT || "100");

  if (!CONTAINER_MODULE_ADDRESS || !QUOTE_HELPER_ADDRESS || !USER_CARD_ADDRESS || !USDC_ADDRESS) {
    throw new Error("缺少依赖地址，请检查 base-FactoryAndModule.json 或设置环境变量");
  }

  const checkCode = async (addr: string, name: string) => {
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") throw new Error(`${name} 无代码: ${addr}`);
  };
  await checkCode(CONTAINER_MODULE_ADDRESS, "Container Module");
  await checkCode(QUOTE_HELPER_ADDRESS, "Quote Helper");
  await checkCode(USER_CARD_ADDRESS, "User Card");

  // 1. 部署新 Deployer
  console.log("1. 部署 BeamioAccountDeployer...");
  const DeployerFactory = await ethers.getContractFactory("BeamioAccountDeployer");
  const newDeployer = await DeployerFactory.deploy();
  await newDeployer.waitForDeployment();
  const newDeployerAddress = await newDeployer.getAddress();
  console.log("   新 Deployer:", newDeployerAddress);

  // 2. 部署新 AA Factory
  console.log("2. 部署 BeamioFactoryPaymasterV07...");
  // 等待 Deployer 交易确认
  await new Promise(resolve => setTimeout(resolve, 5000));
  const FactoryFactory = await ethers.getContractFactory("BeamioFactoryPaymasterV07");
  const deployTx = await FactoryFactory.deploy(
    INITIAL_ACCOUNT_LIMIT,
    newDeployerAddress,
    CONTAINER_MODULE_ADDRESS,
    QUOTE_HELPER_ADDRESS,
    USER_CARD_ADDRESS,
    USDC_ADDRESS
  );
  const newFactory = await deployTx.waitForDeployment();
  await newFactory.waitForDeployment();
  const newFactoryAddress = await newFactory.getAddress();
  console.log("   新 AA Factory:", newFactoryAddress);

  // 3. 绑定 Deployer -> Factory
  console.log("3. 设置 Deployer.factory = 新 Factory...");
  const setFactoryTx = await newDeployer.setFactory(newFactoryAddress);
  await setFactoryTx.wait();
  console.log("   已设置");

  // 4. 保存部署信息
  const deploymentInfo = {
    network: networkName,
    chainId: networkInfo.chainId.toString(),
    deployer: signer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      beamioContainerModule: existing.contracts?.beamioContainerModule || { address: CONTAINER_MODULE_ADDRESS },
      beamioUserCardPlaceholder: existing.contracts?.beamioUserCardPlaceholder,
      beamioFactoryPaymaster: {
        address: newFactoryAddress,
        initialAccountLimit: INITIAL_ACCOUNT_LIMIT,
        deployer: newDeployerAddress,
        containerModule: CONTAINER_MODULE_ADDRESS,
        quoteHelper: QUOTE_HELPER_ADDRESS,
        userCard: USER_CARD_ADDRESS,
        usdc: USDC_ADDRESS,
        transactionHash: newFactory.deploymentTransaction()?.hash,
        note: "Redeployed with fixed BeamioAccount (paymaster/signature parsing)",
      },
    },
  };
  if (!fs.existsSync(DEPLOYMENTS_DIR)) fs.mkdirSync(DEPLOYMENTS_DIR, { recursive: true });
  fs.writeFileSync(DEPLOYMENT_FILE, JSON.stringify(deploymentInfo, null, 2));
  console.log("4. 已写入:", DEPLOYMENT_FILE);

  // 5. 更新 config/base-addresses.ts
  const configContent = `/**
 * Base Mainnet 合约地址与链配置（供 SilentPassUI、SDK 等跨项目引用）
 * 与 deployments/BASE_MAINNET_FACTORIES.md 保持一致，请勿在 APP 中写死其他来源的地址。
 */
export const BASE_MAINNET_CHAIN_ID = 8453

export const BASE_MAINNET_FACTORIES = {
  /** AA 账户工厂 (BeamioFactoryPaymasterV07) */
  AA_FACTORY: '${newFactoryAddress}',
  /** UserCard 工厂 (BeamioUserCardFactoryPaymasterV07) */
  CARD_FACTORY: '${getCardFactoryForConfig()}',
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
  fs.writeFileSync(CONFIG_PATH, configContent);
  console.log("5. 已更新 config/base-addresses.ts 中的 AA_FACTORY");

  const configDir = path.join(__dirname, "..", "config");
  const jsonPath = path.join(configDir, "base-addresses.json");
  fs.writeFileSync(
    jsonPath,
    JSON.stringify(
      {
        BASE_MAINNET_CHAIN_ID: 8453,
        AA_FACTORY: newFactoryAddress,
        CARD_FACTORY: process.env.CARD_FACTORY_ADDRESS || getCardFactoryForConfig(),
      },
      null,
      2
    )
  );
  console.log("   已更新 config/base-addresses.json（供 API 等读取）");

  // 同步更新 x402sdk 内 chainAddresses（避免 rootDir 限制）
  const chainAddressesPath = path.join(__dirname, "..", "src", "x402sdk", "src", "chainAddresses.ts");
  const chainAddressesContent = `/**
 * Base 主网 AA Factory 地址。
 * 与 config/base-addresses.ts 保持一致；运行 npm run redeploy:aa-factory:base 后会同步更新此处。
 */
export const BASE_AA_FACTORY = '${newFactoryAddress}'
`;
  if (fs.existsSync(path.dirname(chainAddressesPath))) {
    fs.writeFileSync(chainAddressesPath, chainAddressesContent);
    console.log("   已同步 src/x402sdk/src/chainAddresses.ts");
  }

  // 同步更新 SilentPassUI 内 chainAddresses（避免 webpack 解析 repo 根 config）
  const uiChainPath = path.join(__dirname, "..", "src", "SilentPassUI", "src", "config", "chainAddresses.ts");
  const CARD_FACTORY_ADDR = process.env.CARD_FACTORY_ADDRESS || getCardFactoryForConfig();
  const uiChainContent = `/**
 * Base 主网合约地址（与项目根 config/base-addresses.ts 保持一致）。
 * 重部署 AA Factory 后运行 npm run redeploy:aa-factory:base 会同步更新根 config 与本文件。
 */
export const BASE_MAINNET_CHAIN_ID = 8453

export const BASE_MAINNET_FACTORIES = {
  /** AA 账户工厂 (BeamioFactoryPaymasterV07) */
  AA_FACTORY: '${newFactoryAddress}',
  /** UserCard 工厂 (BeamioUserCardFactoryPaymasterV07) */
  CARD_FACTORY: '${CARD_FACTORY_ADDR}',
} as const
`;
  if (fs.existsSync(path.dirname(uiChainPath))) {
    fs.writeFileSync(uiChainPath, uiChainContent);
    console.log("   已同步 src/SilentPassUI/src/config/chainAddresses.ts");
  }

  // 6. 可选：Card Factory setAAFactory
  const CARD_FACTORY_ADDRESS =
    process.env.CARD_FACTORY_ADDRESS || getCardFactoryForConfig();
  const CARD_FACTORY_OWNER_PK = process.env.CARD_FACTORY_OWNER_PK;
  if (CARD_FACTORY_OWNER_PK) {
    console.log("6. 调用 Card Factory setAAFactory...");
    const cardFactoryAbi = [
      "function setAAFactory(address f) external",
      "function owner() external view returns (address)",
    ];
    const cardOwnerWallet = new ethers.Wallet(CARD_FACTORY_OWNER_PK, ethers.provider);
    const cardFactory = new ethers.Contract(CARD_FACTORY_ADDRESS, cardFactoryAbi, cardOwnerWallet);
    const owner = await cardFactory.owner();
    if (owner.toLowerCase() !== cardOwnerWallet.address.toLowerCase()) {
      console.warn("   ⚠️  当前私钥不是 Card Factory owner，跳过 setAAFactory");
    } else {
      const tx = await cardFactory.setAAFactory(newFactoryAddress);
      await tx.wait();
      console.log("   已调用 setAAFactory(", newFactoryAddress, ")");
    }
  } else {
    console.log("6. 未设置 CARD_FACTORY_OWNER_PK，跳过 Card Factory setAAFactory");
    console.log("   请由 Card Factory owner 执行:");
    console.log(`   npx hardhat run scripts/setCardFactoryAAFactory.ts --network base`);
    console.log("   或链上调用 setAAFactory('" + newFactoryAddress + "')");
  }

  // 验证合约（可选）
  try {
    await verifyContract(
      newFactoryAddress,
      [
        INITIAL_ACCOUNT_LIMIT,
        newDeployerAddress,
        CONTAINER_MODULE_ADDRESS,
        QUOTE_HELPER_ADDRESS,
        USER_CARD_ADDRESS,
        USDC_ADDRESS,
      ],
      "BeamioFactoryPaymasterV07"
    );
  } catch (e) {
    console.warn("验证失败（可忽略）:", (e as Error).message);
  }

  console.log("\n" + "=".repeat(60));
  console.log("完成。新 AA Factory:", newFactoryAddress);
  console.log("=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
