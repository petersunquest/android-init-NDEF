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
import { homedir } from "os";
import { fileURLToPath } from "url";
import { verifyContract } from "./utils/verifyContract.js";
import { execSync } from "child_process";
import { ethers as ethersJs } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

function loadSignerPk(): string {
  if (process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.trim()) {
    return process.env.PRIVATE_KEY.startsWith("0x")
      ? process.env.PRIVATE_KEY
      : `0x${process.env.PRIVATE_KEY}`;
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
  const pk = loadSignerPk();
  const deployer = new ethersJs.NonceManager(new ethers.Wallet(pk, ethers.provider));
  const deployerAddress = await deployer.getAddress();
  const networkInfo = await ethers.provider.getNetwork();
  const chainId = Number(networkInfo.chainId);
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const configDir = path.join(__dirname, "..", "config");
  const configJsonPath = path.join(configDir, "base-addresses.json");

  console.log("=".repeat(60));
  console.log("重新部署 Card Factory 并更新配置");
  console.log("=".repeat(60));
  console.log("部署账户:", deployerAddress);
  console.log("网络:", networkInfo.name, "Chain ID:", chainId);
  console.log();

  if (chainId !== 8453) {
    console.log("⚠️  当前非 Base 主网 (8453)，请确认 USDC/AA_FACTORY 适用该链");
  }

  // AA_FACTORY：优先从 config/base-addresses.json 读取
  let AA_FACTORY_ADDRESS = process.env.AA_FACTORY_ADDRESS || "";
  if (!AA_FACTORY_ADDRESS && fs.existsSync(configJsonPath)) {
    const cfg = JSON.parse(fs.readFileSync(configJsonPath, "utf-8"));
    if (cfg.AA_FACTORY) AA_FACTORY_ADDRESS = cfg.AA_FACTORY;
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
    console.log("  Owner:", deployerAddress);
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
  const userCardDeployer = await DeployerFactory.connect(deployer).deploy();
  await userCardDeployer.waitForDeployment();
  const deployerContractAddress = await userCardDeployer.getAddress();
  console.log("  BeamioUserCardDeployerV07:", deployerContractAddress);

  await new Promise((r) => setTimeout(r, 3000));
  await verifyContract(deployerContractAddress, [], "BeamioUserCardDeployerV07");

  // ---------- 2. 部署 BeamioUserCardFactoryPaymasterV07 ----------
  console.log("\n步骤 2: 部署 BeamioUserCardFactoryPaymasterV07...");
  const USER_CARD_METADATA_BASE_URI = "https://beamio.app/api/metadata/0x";
  const FactoryFactory = await ethers.getContractFactory("BeamioUserCardFactoryPaymasterV07");
  const factory = await FactoryFactory.connect(deployer).deploy(
    USDC_ADDRESS,
    REDEEM_MODULE_ADDRESS,
    QUOTE_HELPER_ADDRESS,
    deployerContractAddress,
    AA_FACTORY_ADDRESS,
    deployerAddress
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
      deployerContractAddress,
      AA_FACTORY_ADDRESS,
      deployerAddress,
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
    deployer: deployerAddress,
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
        metadataBaseURI: USER_CARD_METADATA_BASE_URI,
        owner: deployerAddress,
        transactionHash: factory.deploymentTransaction()?.hash,
      },
    },
  };

  const outPath = path.join(deploymentsDir, `${networkInfo.name}-UserCardFactory.json`);
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\n4. 部署信息已保存:", outPath);

  // ---------- 5. 更新 config/base-addresses.json（全局单一数据源，各模块从 config/contract-addresses 读取）----------
  let baseJson: Record<string, unknown> = {};
  if (fs.existsSync(configJsonPath)) {
    baseJson = JSON.parse(fs.readFileSync(configJsonPath, "utf-8"));
  }
  baseJson.CARD_FACTORY = factoryAddress;
  baseJson.AA_FACTORY = baseJson.AA_FACTORY ?? AA_FACTORY_ADDRESS;
  baseJson.BASE_MAINNET_CHAIN_ID = baseJson.BASE_MAINNET_CHAIN_ID ?? 8453;
  fs.writeFileSync(configJsonPath, JSON.stringify(baseJson, null, 2));
  console.log("5. 已更新 config/base-addresses.json（全局配置，各模块自动生效）");

  // ---------- 6. 更新 deployments/BASE_MAINNET_FACTORIES.md（与 deployFactoryAndModule 同源脚本）----------
  try {
    execSync("node scripts/writeBaseMainnetFactoriesMd.mjs", {
      cwd: path.join(__dirname, ".."),
      stdio: "inherit",
    });
    console.log("6. 已更新 deployments/BASE_MAINNET_FACTORIES.md");
  } catch {
    console.warn("6. 跳过 BASE_MAINNET_FACTORIES.md（writeBaseMainnetFactoriesMd 失败，请检查 config/base-addresses.json 含 AA_FACTORY 与 CARD_FACTORY）");
  }

  console.log("\n" + "=".repeat(60));
  console.log("部署与配置更新完成");
  console.log("=".repeat(60));
  console.log("\n新地址:");
  console.log("  BeamioUserCardDeployerV07:     ", deployerContractAddress);
  console.log("  BeamioUserCardFactoryPaymasterV07:", factoryAddress);
  console.log("\n已更新:");
  console.log("  - config/base-addresses.json（全局配置，各模块自动生效）");
  console.log("  - deployments/BASE_MAINNET_FACTORIES.md");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
