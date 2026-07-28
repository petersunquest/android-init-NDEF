/**
 * 重新部署 BeamioUserCardDeployerV07 与 BeamioUserCardFactoryPaymasterV07。
 * 不部署 BeamioOracle、BeamioAAAccountFactoryPaymaster，使用已有地址：
 *   BeamioOracle = 0xDa4AE8301262BdAaf1bb68EC91259E6C512A9A2B
 *   BASE_AA_FACTORY = 0x4b31D6a05Cdc817CAc1B06369555b37a5b182122（见 config/base-addresses.json）
 *
 * RedeemModule、QuoteHelper 从已有部署 base-UserCardFactory.json 读取（或环境变量覆盖）。
 *
 * 运行（Base 主网）：
 *   npx hardhat run scripts/redeployUserCardFactoryAndDeployer.ts --network base
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { verifyContract } from "./utils/verifyContract.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_AA_FACTORY = "0x4b31D6a05Cdc817CAc1B06369555b37a5b182122";
const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const networkInfo = await ethers.provider.getNetwork();
  const chainId = Number(networkInfo.chainId);
  const deploymentsDir = path.join(__dirname, "..", "deployments");

  console.log("=".repeat(60));
  console.log("重新部署 BeamioUserCardDeployerV07 + BeamioUserCardFactoryPaymasterV07");
  console.log("=".repeat(60));
  console.log("部署账户:", deployer.address);
  console.log("网络:", networkInfo.name, "Chain ID:", chainId);
  console.log("使用已有: AA_FACTORY =", BASE_AA_FACTORY);
  console.log();

  if (chainId !== 8453) {
    console.log("⚠️  当前非 Base 主网 (8453)，请确认 USDC/AA_FACTORY 适用该链");
  }

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
  const AA_FACTORY_ADDRESS = process.env.AA_FACTORY_ADDRESS || BASE_AA_FACTORY;

  console.log("依赖地址:");
  console.log("  USDC:", USDC_ADDRESS);
  console.log("  RedeemModule:", REDEEM_MODULE_ADDRESS);
  console.log("  QuoteHelper:", QUOTE_HELPER_ADDRESS);
  console.log("  AA_FACTORY (不部署):", AA_FACTORY_ADDRESS);
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
  const USER_CARD_METADATA_BASE_URI = "https://beamio.app/api/metadata/0x";
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
        metadataBaseURI: USER_CARD_METADATA_BASE_URI,
        owner: deployer.address,
        transactionHash: factory.deploymentTransaction()?.hash,
      },
    },
  };

  const outPath = path.join(deploymentsDir, `${networkInfo.name}-UserCardFactory-Redeploy.json`);
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\n部署信息已保存:", outPath);

  console.log("\n" + "=".repeat(60));
  console.log("部署完成");
  console.log("=".repeat(60));
  console.log("\n新地址:");
  console.log("  BeamioUserCardDeployerV07:     ", deployerContractAddress);
  console.log("  BeamioUserCardFactoryPaymasterV07:", factoryAddress);
  console.log("\n请更新以下配置为上述 Factory 地址:");
  console.log("  - src/x402sdk/src/chainAddresses.ts 的 BASE_CARD_FACTORY");
  console.log("  - config/base-addresses.ts 的 CARD_FACTORY");
  console.log("  - src/SilentPassUI/src/config/chainAddresses.ts 的 CARD_FACTORY");
  console.log("  - deployments/BASE_MAINNET_FACTORIES.md");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
