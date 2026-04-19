/**
 * 重新部署 AA Factory（含修复后的 BeamioAccount 逻辑），并更新 config、Card Factory 依赖。
 *
 * 步骤：
 * 1. 部署新的 BeamioAccountDeployer
 * 2. 从 base-FactoryAndModule.json 读取 containerModule / quoteHelper / userCard / usdc
 * 3. 部署新的 BeamioFactoryPaymasterV07（字节码内含修复后的 BeamioAccount）
 * 4. 调用 newDeployer.setFactory(newFactoryAddress)
 * 5. 写回 deployments/base-FactoryAndModule.json
 * 6. 更新 config/base-addresses.json 中的 AA_FACTORY，并同步 x402sdk / BASE_MAINNET_FACTORIES.md
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
import { homedir } from "os";
import { fileURLToPath } from "url";
import { verifyContract } from "./utils/verifyContract.js";
import { execSync } from "child_process";
import { getAddress, ethers as ethersLib, type Signer } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const CONFIG_JSON_PATH = path.join(__dirname, "..", "config", "base-addresses.json");
const DEPLOYMENTS_DIR = path.join(__dirname, "..", "deployments");
const DEPLOYMENT_FILE = path.join(DEPLOYMENTS_DIR, "base-FactoryAndModule.json");
const FULL_ACCOUNT_FILE = path.join(DEPLOYMENTS_DIR, "base-FullAccountAndUserCard.json");

/** 当前 Base 主网 Card Factory，写入 config 时保持不改；与 config/base-addresses.json 一致 */
function getCardFactoryForConfig(): string {
  if (process.env.CARD_FACTORY_ADDRESS) return process.env.CARD_FACTORY_ADDRESS;
  if (fs.existsSync(FULL_ACCOUNT_FILE)) {
    const data = JSON.parse(fs.readFileSync(FULL_ACCOUNT_FILE, "utf-8"));
    const addr = data.contracts?.beamioUserCardFactoryPaymaster?.address;
    if (addr) return addr;
  }
  if (fs.existsSync(CONFIG_JSON_PATH)) {
    const data = JSON.parse(fs.readFileSync(CONFIG_JSON_PATH, "utf-8"));
    if (data.CARD_FACTORY) return data.CARD_FACTORY;
  }
  return "0x2EB245646de404b2Dce87E01C6282C131778bb05";
}

function loadSignerPk(): string {
  if (process.env.PRIVATE_KEY?.trim()) {
    const pk = process.env.PRIVATE_KEY.trim();
    return pk.startsWith("0x") ? pk : `0x${pk}`;
  }
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) {
    throw new Error("未找到 PRIVATE_KEY，且 ~/.master.json 不存在");
  }
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk || typeof pk !== "string") {
    throw new Error("未找到 PRIVATE_KEY，且 ~/.master.json 缺少 settle_contractAdmin[0]");
  }
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

async function main() {
  const { ethers } = await networkModule.connect();
  let deployer: Signer;
  const signers = await ethers.getSigners();
  if (signers.length > 0) {
    deployer = signers[0];
  } else {
    const pk = loadSignerPk();
    deployer = new ethersLib.NonceManager(new ethersLib.Wallet(pk, ethers.provider));
  }
  const deployerAddress = await deployer.getAddress();
  const networkInfo = await ethers.provider.getNetwork();
  const networkName = networkInfo.name;

  if (networkName !== "base") {
    console.warn("⚠️  本脚本面向 Base 主网。当前网络:", networkName);
  }

  console.log("=".repeat(60));
  console.log("重新部署 AA Factory 并更新配置");
  console.log("=".repeat(60));
  console.log("网络:", networkName);
  console.log("部署账户:", deployerAddress);
  console.log("余额:", ethers.formatEther(await ethers.provider.getBalance(deployerAddress)), "ETH\n");

  // 读取现有依赖（Base）
  if (!fs.existsSync(DEPLOYMENT_FILE)) {
    throw new Error(`缺少部署文件: ${DEPLOYMENT_FILE}，请先部署 Factory 或提供依赖地址`);
  }
  const existing = JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf-8"));
  const oldFactory = existing.contracts?.beamioFactoryPaymaster;
  const CONTAINER_MODULE_ADDRESS =
    process.env.CONTAINER_MODULE_ADDRESS || existing.contracts?.beamioContainerModule?.address;
  let QUOTE_HELPER_ADDRESS =
    process.env.QUOTE_HELPER_ADDRESS || oldFactory?.quoteHelper;
  let USER_CARD_ADDRESS = process.env.USER_CARD_ADDRESS || oldFactory?.userCard;
  if (fs.existsSync(FULL_ACCOUNT_FILE)) {
    const fa = JSON.parse(fs.readFileSync(FULL_ACCOUNT_FILE, "utf-8"));
    if (!QUOTE_HELPER_ADDRESS && fa.existing?.beamioQuoteHelper) {
      QUOTE_HELPER_ADDRESS = fa.existing.beamioQuoteHelper;
    }
    if (!USER_CARD_ADDRESS && fa.contracts?.beamioUserCard?.address) {
      USER_CARD_ADDRESS = fa.contracts.beamioUserCard.address;
    }
  }
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
  const newDeployer = await DeployerFactory.connect(deployer).deploy();
  await newDeployer.waitForDeployment();
  const newDeployerAddress = await newDeployer.getAddress();
  console.log("   新 Deployer:", newDeployerAddress);

  // 2. 部署新 AA Factory
  console.log("2. 部署 BeamioFactoryPaymasterV07...");
  // 等待 Deployer 交易确认
  await new Promise(resolve => setTimeout(resolve, 5000));
  const FactoryFactory = await ethers.getContractFactory("BeamioFactoryPaymasterV07");
  const deployTx = await FactoryFactory.connect(deployer).deploy(
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
  const setFactoryTx = await newDeployer.connect(deployer).setFactory(newFactoryAddress);
  await setFactoryTx.wait();
  console.log("   已设置");

  // 4. 保存部署信息
  const deploymentInfo = {
    network: networkName,
    chainId: networkInfo.chainId.toString(),
    deployer: deployerAddress,
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

  // 5. 更新 config/base-addresses.json（全局单一数据源，各模块从 config/contract-addresses 读取）
  const configDir = path.join(__dirname, "..", "config");
  const jsonPath = path.join(configDir, "base-addresses.json");
  let baseJson: Record<string, unknown> = {};
  if (fs.existsSync(jsonPath)) {
    baseJson = JSON.parse(fs.readFileSync(jsonPath, "utf-8"));
  }
  baseJson.AA_FACTORY = getAddress(newFactoryAddress);
  baseJson.CARD_FACTORY = baseJson.CARD_FACTORY ?? process.env.CARD_FACTORY_ADDRESS ?? getCardFactoryForConfig();
  baseJson.BASE_MAINNET_CHAIN_ID = baseJson.BASE_MAINNET_CHAIN_ID ?? 8453;
  fs.writeFileSync(jsonPath, JSON.stringify(baseJson, null, 2));
  console.log("   已更新 config/base-addresses.json（全局配置，各模块自动生效）");
  try {
    execSync("node scripts/syncBaseAddressesJsonToX402sdkChainAddresses.mjs", {
      cwd: path.join(__dirname, ".."),
      stdio: "inherit",
    });
  } catch {
    console.warn("   ⚠️  同步 x402sdk chainAddresses 失败，请手动: node scripts/syncBaseAddressesJsonToX402sdkChainAddresses.mjs");
  }
  try {
    execSync("node scripts/syncBeamioAccountToX402sdk.mjs", {
      cwd: path.join(__dirname, ".."),
      stdio: "inherit",
    });
    console.log("   已同步 BeamioAccount artifact -> x402sdk");
  } catch {
    console.warn("   ⚠️  同步 BeamioAccount artifact 失败，请执行: npm run compile && npm run sync:beamio-account-x402sdk");
  }

  if (chainId === 8453) {
    try {
      execSync("node scripts/writeBaseMainnetFactoriesMd.mjs", {
        cwd: path.join(__dirname, ".."),
        stdio: "inherit",
      });
      console.log("   已更新 deployments/BASE_MAINNET_FACTORIES.md");
    } catch {
      console.warn("   ⚠️  跳过 BASE_MAINNET_FACTORIES.md（需 config 含 AA_FACTORY 与 CARD_FACTORY）");
    }
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
