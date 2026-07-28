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

/**
 * 部署 Factory 和 Container Module
 * 
 * 部署顺序：
 * 1. BeamioContainerModuleExternalLibV07 — hash / open 校验等
 * 2. BeamioContainerModuleExternalLib2V07 — preExecute + 转账管线
 * 3. BeamioContainerModuleV07 — 链接上述两个 library
 * 4. BeamioFactoryPaymasterV07 - Factory/Paymaster（需要多个依赖）
 * 
 * Factory 构造函数参数：
 * - initialAccountLimit: 初始账户限制（建议 100-1000）
 * - deployer_: BeamioAccountDeployer 地址
 * - module_: BeamioContainerModuleV07 地址
 * - quoteHelper_: BeamioQuoteHelperV07 地址
 * - userCard_: BeamioUserCard 地址
 * - usdc_: USDC 代币地址
 *
 * 签名者与 redeployCardFactory / deployUserCardFactory 一致：
 * - 优先 Hardhat 配置的账户（如 .env PRIVATE_KEY）
 * - 否则读取 ~/.master.json 的 settle_contractAdmin[0]
 *
 * 依赖解析顺序（与 deployUserCardFactory 类似）：环境变量 → FullSystem.json → FullAccountAndUserCard.json → FactoryAndModule.json
 */
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
    try {
      const pk = loadSignerPk();
      deployer = new ethersLib.NonceManager(new ethersLib.Wallet(pk, ethers.provider));
    } catch {
      console.error(
        "❌ 未配置部署账户：请在 .env 设置 PRIVATE_KEY（Base/Base Sepolia），或配置 ~/.master.json 的 settle_contractAdmin[0]。"
      );
      process.exit(1);
    }
  }

  const deployerAddress = await deployer.getAddress();

  console.log("=".repeat(60));
  console.log("部署 Factory 和 Container Module");
  console.log("=".repeat(60));
  console.log("部署账户:", deployerAddress);
  console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployerAddress)), "ETH");
  
  const networkInfo = await ethers.provider.getNetwork();
  console.log("网络:", networkInfo.name, "(Chain ID:", networkInfo.chainId.toString() + ")");
  
  const deploymentInfo: any = {
    network: networkInfo.name,
    chainId: networkInfo.chainId.toString(),
    deployer: deployerAddress,
    timestamp: new Date().toISOString(),
    contracts: {}
  };
  
  // ============================================================
  // 1. 部署两个 Container external library + BeamioContainerModuleV07
  // ============================================================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 1a: 部署 BeamioContainerModuleExternalLibV07");
  console.log("=".repeat(60));

  const ExtLibFactory = await ethers.getContractFactory("BeamioContainerModuleExternalLibV07");
  const containerExtLib = await ExtLibFactory.connect(deployer).deploy();
  await containerExtLib.waitForDeployment();
  const containerExtLibAddress = await containerExtLib.getAddress();
  console.log("✅ BeamioContainerModuleExternalLibV07:", containerExtLibAddress);
  deploymentInfo.contracts.beamioContainerModuleExternalLib = {
    address: containerExtLibAddress,
    transactionHash: containerExtLib.deploymentTransaction()?.hash,
  };
  await verifyContract(containerExtLibAddress, [], "BeamioContainerModuleExternalLibV07");

  console.log("\n" + "=".repeat(60));
  console.log("步骤 1b: 部署 BeamioContainerModuleExternalLib2V07");
  console.log("=".repeat(60));
  const ExtLib2Factory = await ethers.getContractFactory("BeamioContainerModuleExternalLib2V07");
  const containerExtLib2 = await ExtLib2Factory.connect(deployer).deploy();
  await containerExtLib2.waitForDeployment();
  const containerExtLib2Address = await containerExtLib2.getAddress();
  console.log("✅ BeamioContainerModuleExternalLib2V07:", containerExtLib2Address);
  deploymentInfo.contracts.beamioContainerModuleExternalLib2 = {
    address: containerExtLib2Address,
    transactionHash: containerExtLib2.deploymentTransaction()?.hash,
  };
  await verifyContract(containerExtLib2Address, [], "BeamioContainerModuleExternalLib2V07");

  console.log("\n" + "=".repeat(60));
  console.log("步骤 1c: 部署 BeamioContainerModuleV07（链接两个 library）");
  console.log("=".repeat(60));

  const ContainerModuleFactory = await ethers.getContractFactory("BeamioContainerModuleV07", {
    libraries: {
      BeamioContainerModuleExternalLibV07: containerExtLibAddress,
      BeamioContainerModuleExternalLib2V07: containerExtLib2Address,
    },
  });
  const containerModule = await ContainerModuleFactory.connect(deployer).deploy();
  await containerModule.waitForDeployment();
  const containerModuleAddress = await containerModule.getAddress();

  console.log("✅ BeamioContainerModuleV07 部署成功!");
  console.log("合约地址:", containerModuleAddress);

  deploymentInfo.contracts.beamioContainerModule = {
    address: containerModuleAddress,
    transactionHash: containerModule.deploymentTransaction()?.hash,
    linkedLibraries: {
      beamioContainerModuleExternalLib: containerExtLibAddress,
      beamioContainerModuleExternalLib2: containerExtLib2Address,
    },
  };

  await verifyContract(containerModuleAddress, [], "BeamioContainerModuleV07");
  
  // ============================================================
  // 2. 部署 BeamioFactoryPaymasterV07
  // ============================================================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 2: 部署 BeamioFactoryPaymasterV07");
  console.log("=".repeat(60));
  
  // 从部署记录读取依赖（对齐 deployUserCardFactory：多文件回退）
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  let deployerAddressFromFile = "";
  let quoteHelperAddressFromFile = "";
  let userCardFromFile = "";

  const readJson = (p: string) => {
    try {
      return JSON.parse(fs.readFileSync(p, "utf-8"));
    } catch {
      return null;
    }
  };

  const fullSystemFile = path.join(deploymentsDir, `${networkInfo.name}-FullSystem.json`);
  const fullSystemData = readJson(fullSystemFile);
  if (fullSystemData?.contracts?.beamioAccountDeployer?.address) {
    deployerAddressFromFile = fullSystemData.contracts.beamioAccountDeployer.address;
  }
  if (fullSystemData?.contracts?.beamioQuoteHelper?.address) {
    quoteHelperAddressFromFile = fullSystemData.contracts.beamioQuoteHelper.address;
  }

  const fullAccFile = path.join(deploymentsDir, `${networkInfo.name}-FullAccountAndUserCard.json`);
  const fullAccData = readJson(fullAccFile);
  if (fullAccData) {
    if (!deployerAddressFromFile && fullAccData.contracts?.beamioAccountDeployer?.address) {
      deployerAddressFromFile = fullAccData.contracts.beamioAccountDeployer.address;
    }
    if (!quoteHelperAddressFromFile && fullAccData.existing?.beamioQuoteHelper) {
      quoteHelperAddressFromFile = fullAccData.existing.beamioQuoteHelper;
    }
    if (fullAccData.contracts?.beamioUserCard?.address) {
      userCardFromFile = fullAccData.contracts.beamioUserCard.address;
    }
  }

  const factoryModuleFile = path.join(deploymentsDir, `${networkInfo.name}-FactoryAndModule.json`);
  const factoryModuleData = readJson(factoryModuleFile);
  const prevFp = factoryModuleData?.contracts?.beamioFactoryPaymaster;
  if (prevFp) {
    if (!deployerAddressFromFile && prevFp.deployer) deployerAddressFromFile = prevFp.deployer;
    if (!quoteHelperAddressFromFile && prevFp.quoteHelper) quoteHelperAddressFromFile = prevFp.quoteHelper;
    if (!userCardFromFile && prevFp.userCard) userCardFromFile = prevFp.userCard;
  }

  const DEPLOYER_ADDRESS = process.env.DEPLOYER_ADDRESS || deployerAddressFromFile;
  const QUOTE_HELPER_ADDRESS = process.env.QUOTE_HELPER_ADDRESS || quoteHelperAddressFromFile;
  let USER_CARD_ADDRESS = process.env.USER_CARD_ADDRESS || userCardFromFile;
  
  // 根据网络自动选择 USDC 地址
  const chainId = Number(networkInfo.chainId);
  const defaultUSDCAddress = chainId === 8453 
    ? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" // Base Mainnet
    : "0x036CbD53842c5426634e7929541eC2318f3dCF7e"; // Base Sepolia
  const USDC_ADDRESS = process.env.USDC_ADDRESS || defaultUSDCAddress;
  const INITIAL_ACCOUNT_LIMIT = parseInt(process.env.INITIAL_ACCOUNT_LIMIT || "100");
  
  console.log("配置参数:");
  console.log("  Container Module:", containerModuleAddress);
  console.log("  Deployer:", DEPLOYER_ADDRESS || "需要设置");
  console.log("  Quote Helper:", QUOTE_HELPER_ADDRESS || "需要设置");
  console.log("  User Card:", USER_CARD_ADDRESS || "将部署占位符合约");
  console.log("  USDC:", USDC_ADDRESS);
  console.log("  Account Limit:", INITIAL_ACCOUNT_LIMIT);
  
  // 检查必需的参数
  const missingDeps: string[] = [];
  if (!DEPLOYER_ADDRESS) missingDeps.push("DEPLOYER_ADDRESS (BeamioAccountDeployer)");
  if (!QUOTE_HELPER_ADDRESS) missingDeps.push("QUOTE_HELPER_ADDRESS (BeamioQuoteHelperV07)");
  if (!USDC_ADDRESS) missingDeps.push("USDC_ADDRESS (USDC token)");
  
  if (missingDeps.length > 0) {
    console.log("\n⚠️  缺少 Factory 部署所需的依赖:");
    missingDeps.forEach((dep) => console.log(`  - ${dep}`));
    console.log("\n💡 建议:");
    const networkCmd = chainId === 8453 ? "npm run deploy:full:base" : "npm run deploy:full:base-sepolia";
    console.log(`  1. 先运行完整系统部署: ${networkCmd}`);
    console.log("  2. 或在 .env 中设置 DEPLOYER_ADDRESS / QUOTE_HELPER_ADDRESS");
    console.log("  3. 或确保存在 deployments 下 FullSystem / FullAccountAndUserCard / FactoryAndModule 记录");
    console.log("\n✅ Container Module（含两个 library）已部署；已写入 deployments。");
    console.log("    Container Module 地址:", containerModuleAddress);
    if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
    const partialFile = path.join(deploymentsDir, `${networkInfo.name}-FactoryAndModule.json`);
    fs.writeFileSync(partialFile, JSON.stringify(deploymentInfo, null, 2));
    console.log("    部署片段已保存:", partialFile);
    return;
  }
  
  // 如果没有提供 UserCard 地址，部署占位符合约
  let placeholderDeployed = false;
  if (!USER_CARD_ADDRESS) {
    console.log("\n" + "=".repeat(60));
    console.log("步骤 1.5: 部署 BeamioUserCardPlaceholder (临时占位符)");
    console.log("=".repeat(60));
    console.log("💡 注意: 这是临时占位符合约，用于解决 Factory 和 UserCard 的循环依赖");
    console.log("   稍后可以部署真正的 UserCard 并更新 Factory");
    
    try {
      const PlaceholderFactory = await ethers.getContractFactory("BeamioUserCardPlaceholder");
      const placeholder = await PlaceholderFactory.connect(deployer).deploy();
      await placeholder.waitForDeployment();
      USER_CARD_ADDRESS = await placeholder.getAddress();
      placeholderDeployed = true;
      
      console.log("✅ BeamioUserCardPlaceholder 部署成功!");
      console.log("合约地址:", USER_CARD_ADDRESS);
      
      // 等待区块确认
      console.log("等待区块确认...");
      await new Promise(resolve => setTimeout(resolve, 5000));
      
      deploymentInfo.contracts.beamioUserCardPlaceholder = {
        address: USER_CARD_ADDRESS,
        transactionHash: placeholder.deploymentTransaction()?.hash,
        note: "临时占位符合约，稍后应替换为真正的 BeamioUserCard"
      };
    } catch (error: any) {
      console.log("⚠️  占位符合约部署失败:", error.message);
      console.log("   请手动设置 USER_CARD_ADDRESS 环境变量");
      return;
    }
  }
  
  // 验证地址是否有代码
  const checkCode = async (addr: string, name: string, skipIfPlaceholder = false) => {
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") {
      if (skipIfPlaceholder && placeholderDeployed) {
        console.log(`⚠️  ${name} 地址 ${addr} 代码尚未确认，继续部署...`);
        return;
      }
      throw new Error(`${name} 地址 ${addr} 没有合约代码`);
    }
  };
  
  await checkCode(DEPLOYER_ADDRESS, "Deployer");
  await checkCode(QUOTE_HELPER_ADDRESS, "Quote Helper");
  await checkCode(USER_CARD_ADDRESS, "User Card", true);
  // USDC 可能是外部合约，不检查代码
  
  console.log("\n部署 BeamioFactoryPaymasterV07...");
  
  const FactoryFactory = await ethers.getContractFactory("BeamioFactoryPaymasterV07");
  const factory = await FactoryFactory.connect(deployer).deploy(
    INITIAL_ACCOUNT_LIMIT,
    DEPLOYER_ADDRESS,
    containerModuleAddress,
    QUOTE_HELPER_ADDRESS,
    USER_CARD_ADDRESS,
    USDC_ADDRESS
  );
  
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  
  console.log("✅ BeamioFactoryPaymasterV07 部署成功!");
  console.log("合约地址:", factoryAddress);
  
  deploymentInfo.contracts.beamioFactoryPaymaster = {
    address: factoryAddress,
    initialAccountLimit: INITIAL_ACCOUNT_LIMIT,
    deployer: DEPLOYER_ADDRESS,
    containerModule: containerModuleAddress,
    quoteHelper: QUOTE_HELPER_ADDRESS,
    userCard: USER_CARD_ADDRESS,
    usdc: USDC_ADDRESS,
    transactionHash: factory.deploymentTransaction()?.hash
  };
  
  // 自动验证 Factory
  await verifyContract(
    factoryAddress,
    [
      INITIAL_ACCOUNT_LIMIT,
      DEPLOYER_ADDRESS,
      containerModuleAddress,
      QUOTE_HELPER_ADDRESS,
      USER_CARD_ADDRESS,
      USDC_ADDRESS
    ],
    "BeamioFactoryPaymasterV07"
  );

  // 更新根仓 JSON + x402sdk chainAddresses（AA 工厂地址）
  const configDir = path.join(__dirname, "..", "config");
  const baseJsonPath = path.join(configDir, "base-addresses.json");
  let baseJson: Record<string, unknown> = {};
  if (fs.existsSync(baseJsonPath)) {
    baseJson = JSON.parse(fs.readFileSync(baseJsonPath, "utf-8"));
  }
  baseJson.AA_FACTORY = getAddress(factoryAddress);
  baseJson.BEAMIO_ACCOUNT_DEPLOYER = getAddress(DEPLOYER_ADDRESS);
  baseJson.BASE_MAINNET_CHAIN_ID = baseJson.BASE_MAINNET_CHAIN_ID ?? 8453;
  fs.mkdirSync(configDir, { recursive: true });
  fs.writeFileSync(baseJsonPath, JSON.stringify(baseJson, null, 2), "utf-8");
  console.log("✅ 已更新 config/base-addresses.json AA_FACTORY / BEAMIO_ACCOUNT_DEPLOYER");
  try {
    execSync("node scripts/syncBaseAddressesJsonToX402sdkChainAddresses.mjs", {
      cwd: path.join(__dirname, ".."),
      stdio: "inherit",
    });
  } catch {
    console.warn("⚠️  同步 x402sdk chainAddresses 失败，请手动运行: node scripts/syncBaseAddressesJsonToX402sdkChainAddresses.mjs");
  }
  try {
    execSync("node scripts/syncBeamioAccountToX402sdk.mjs", {
      cwd: path.join(__dirname, ".."),
      stdio: "inherit",
    });
    console.log("✅ 已同步 BeamioAccount / Factory artifact 至 x402sdk（initCode 与当前编译一致）");
  } catch {
    console.warn("⚠️  同步 BeamioAccount artifact 失败，请在本仓执行: npm run compile && npm run sync:beamio-account-x402sdk");
  }

  if (chainId === 8453) {
    try {
      execSync("node scripts/writeBaseMainnetFactoriesMd.mjs", {
        cwd: path.join(__dirname, ".."),
        stdio: "inherit",
      });
      console.log("✅ 已更新 deployments/BASE_MAINNET_FACTORIES.md");
    } catch {
      console.warn("⚠️  跳过 BASE_MAINNET_FACTORIES.md（需 config/base-addresses.json 含 CARD_FACTORY）");
    }
  }
  
  // ============================================================
  // 保存部署信息
  // ============================================================
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }
  
  const deploymentFile = path.join(deploymentsDir, `${networkInfo.name}-FactoryAndModule.json`);
  fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
  
  console.log("\n" + "=".repeat(60));
  console.log("部署完成!");
  console.log("=".repeat(60));
  console.log("\n部署信息已保存到:", deploymentFile);
  
  console.log("\n📋 部署摘要:");
  console.log("  - BeamioContainerModuleV07:", containerModuleAddress);
  console.log("  - BeamioFactoryPaymasterV07:", factoryAddress);
  
  console.log("\n⚠️  重要提示:");
  console.log("  1. Factory 会自动尝试设置 Deployer 的 Factory 地址");
  console.log("  2. 可以使用 Factory 创建和管理 BeamioAccount");
  console.log("  3. Factory 同时作为 Paymaster，可以为账户支付 Gas");
  console.log("  4. Card Factory 需指向本 AA Factory：由 owner 调用 setAAFactory(" + factoryAddress + ")（见 setCardFactoryAAFactory.ts）");
  
  if (placeholderDeployed) {
    console.log("\n🔔 占位符合约提示:");
    console.log("  ⚠️  当前 Factory 使用的是占位符 UserCard 地址");
    console.log("  📝 部署真正的 BeamioUserCard 后，请更新 Factory:");
    console.log(`     await factory.setUserCard(realUserCardAddress);`);
    console.log("  💡 真正的 UserCard 需要使用 Factory 地址作为 gateway");
  }
  
  console.log("\n📚 下一步:");
  console.log("  - 使用 Factory 创建账户: factory.createAccount(...)");
  console.log("  - 或使用已部署的 BeamioAccount 调用 initialize(factory, module)");
  if (placeholderDeployed) {
    console.log("  - 部署真正的 BeamioUserCard 并更新 Factory 的 userCard 地址");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
