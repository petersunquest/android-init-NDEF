import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { verifyContract } from "./utils/verifyContract.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * 一体化部署：BeamioAccount 相关项 + BeamioUserCard 及其相关项
 * - 使用**原有** BeamioOracle 和 BeamioQuoteHelperV07（不重新部署）
 * - 新部署：Deployer, BeamioAccount, ContainerModule, Placeholder, AA Factory → UserCard 依赖 → UserCard Factory → BeamioUserCard → 更新 AA Factory.setUserCard
 */
async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();

  console.log("=".repeat(60));
  console.log("一体化部署：BeamioAccount + BeamioUserCard（使用原有 Oracle/QuoteHelper）");
  console.log("=".repeat(60));
  console.log("部署账户:", deployer.address);
  console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");

  const networkInfo = await ethers.provider.getNetwork();
  const chainId = Number(networkInfo.chainId);
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const defaultUSDC = chainId === 8453
    ? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    : "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
  const USDC_ADDRESS = process.env.USDC_ADDRESS || defaultUSDC;
  const ENTRY_POINT_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
  const INITIAL_ACCOUNT_LIMIT = parseInt(process.env.INITIAL_ACCOUNT_LIMIT || "100");

  // ---------- 使用原有 Oracle 和 QuoteHelper ----------
  let oracleAddress = process.env.EXISTING_ORACLE_ADDRESS || "";
  let quoteHelperAddress = process.env.EXISTING_QUOTE_HELPER_ADDRESS || "";
  const fullSystemFile = path.join(deploymentsDir, `${networkInfo.name}-FullSystem.json`);
  if (fs.existsSync(fullSystemFile)) {
    const data = JSON.parse(fs.readFileSync(fullSystemFile, "utf-8"));
    if (!oracleAddress && data.contracts?.beamioOracle?.address) oracleAddress = data.contracts.beamioOracle.address;
    if (!quoteHelperAddress && data.contracts?.beamioQuoteHelper?.address) quoteHelperAddress = data.contracts.beamioQuoteHelper.address;
  }
  if (!oracleAddress || !quoteHelperAddress) {
    console.log("❌ 必须提供原有 Oracle 和 QuoteHelper 地址");
    console.log("  设置 EXISTING_ORACLE_ADDRESS 和 EXISTING_QUOTE_HELPER_ADDRESS，或确保存在", fullSystemFile);
    process.exit(1);
  }
  console.log("\n使用原有合约:");
  console.log("  BeamioOracle:", oracleAddress);
  console.log("  BeamioQuoteHelperV07:", quoteHelperAddress);

  const out: Record<string, unknown> = {
    network: networkInfo.name,
    chainId: networkInfo.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    existing: { beamioOracle: oracleAddress, beamioQuoteHelper: quoteHelperAddress },
    contracts: {},
  };

  const verify = async (addr: string, args: unknown[], name: string) => {
    try {
      await verifyContract(addr, args, name);
    } catch (e: unknown) {
      console.log("⚠️  验证跳过:", (e as Error)?.message ?? "");
    }
  };

  // ==================== 1. BeamioAccountDeployer ====================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 1: 部署 BeamioAccountDeployer");
  console.log("=".repeat(60));
  const AccountDeployerFactory = await ethers.getContractFactory("BeamioAccountDeployer");
  const accountDeployer = await AccountDeployerFactory.deploy();
  await accountDeployer.waitForDeployment();
  const accountDeployerAddress = await accountDeployer.getAddress();
  (out.contracts as Record<string, unknown>).beamioAccountDeployer = { address: accountDeployerAddress, tx: accountDeployer.deploymentTransaction()?.hash };
  console.log("✅ BeamioAccountDeployer:", accountDeployerAddress);
  await verify(accountDeployerAddress, [], "BeamioAccountDeployer");

  // ==================== 2. BeamioAccount ====================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 2: 部署 BeamioAccount");
  console.log("=".repeat(60));
  const BeamioAccountFactory = await ethers.getContractFactory("BeamioAccount");
  const beamioAccount = await BeamioAccountFactory.deploy(ENTRY_POINT_V07);
  await beamioAccount.waitForDeployment();
  const beamioAccountAddress = await beamioAccount.getAddress();
  (out.contracts as Record<string, unknown>).beamioAccount = { address: beamioAccountAddress, entryPoint: ENTRY_POINT_V07, tx: beamioAccount.deploymentTransaction()?.hash };
  console.log("✅ BeamioAccount:", beamioAccountAddress);
  await verify(beamioAccountAddress, [ENTRY_POINT_V07], "BeamioAccount");

  // ==================== 3. BeamioContainerModuleV07 ====================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 3: 部署 BeamioContainerModuleV07");
  console.log("=".repeat(60));
  const ContainerModuleFactory = await ethers.getContractFactory("BeamioContainerModuleV07");
  const containerModule = await ContainerModuleFactory.deploy();
  await containerModule.waitForDeployment();
  const containerModuleAddress = await containerModule.getAddress();
  (out.contracts as Record<string, unknown>).beamioContainerModule = { address: containerModuleAddress, tx: containerModule.deploymentTransaction()?.hash };
  console.log("✅ BeamioContainerModuleV07:", containerModuleAddress);
  await verify(containerModuleAddress, [], "BeamioContainerModuleV07");

  // ==================== 4. BeamioUserCardPlaceholder ====================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 4: 部署 BeamioUserCardPlaceholder（临时）");
  console.log("=".repeat(60));
  const PlaceholderFactory = await ethers.getContractFactory("BeamioUserCardPlaceholder");
  const placeholder = await PlaceholderFactory.deploy();
  await placeholder.waitForDeployment();
  const placeholderAddress = await placeholder.getAddress();
  (out.contracts as Record<string, unknown>).beamioUserCardPlaceholder = { address: placeholderAddress, tx: placeholder.deploymentTransaction()?.hash };
  console.log("✅ BeamioUserCardPlaceholder:", placeholderAddress);
  await new Promise((r) => setTimeout(r, 3000));

  // ==================== 5. BeamioFactoryPaymasterV07 ====================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 5: 部署 BeamioFactoryPaymasterV07");
  console.log("=".repeat(60));
  const AAFactoryFactory = await ethers.getContractFactory("BeamioFactoryPaymasterV07");
  const aaFactory = await AAFactoryFactory.deploy(
    INITIAL_ACCOUNT_LIMIT,
    accountDeployerAddress,
    containerModuleAddress,
    quoteHelperAddress,
    placeholderAddress,
    USDC_ADDRESS
  );
  await aaFactory.waitForDeployment();
  const aaFactoryAddress = await aaFactory.getAddress();
  (out.contracts as Record<string, unknown>).beamioFactoryPaymaster = {
    address: aaFactoryAddress,
    deployer: accountDeployerAddress,
    containerModule: containerModuleAddress,
    quoteHelper: quoteHelperAddress,
    userCard: placeholderAddress,
    usdc: USDC_ADDRESS,
    tx: aaFactory.deploymentTransaction()?.hash,
  };
  console.log("✅ BeamioFactoryPaymasterV07:", aaFactoryAddress);
  await verify(aaFactoryAddress, [INITIAL_ACCOUNT_LIMIT, accountDeployerAddress, containerModuleAddress, quoteHelperAddress, placeholderAddress, USDC_ADDRESS], "BeamioFactoryPaymasterV07");

  // ==================== 6. BeamioUserCard 依赖 ====================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 6: 部署 BeamioUserCard 依赖（RedeemModule + UserCardDeployer）");
  console.log("=".repeat(60));
  const RedeemModuleFactory = await ethers.getContractFactory("BeamioUserCardRedeemModuleVNext");
  const redeemModule = await RedeemModuleFactory.deploy();
  await redeemModule.waitForDeployment();
  const redeemModuleAddress = await redeemModule.getAddress();
  (out.contracts as Record<string, unknown>).redeemModule = { address: redeemModuleAddress, tx: redeemModule.deploymentTransaction()?.hash };
  console.log("✅ BeamioUserCardRedeemModuleVNext:", redeemModuleAddress);
  await verify(redeemModuleAddress, [], "BeamioUserCardRedeemModuleVNext");

  const UserCardDeployerFactory = await ethers.getContractFactory("BeamioUserCardDeployerV07");
  const userCardDeployer = await UserCardDeployerFactory.deploy();
  await userCardDeployer.waitForDeployment();
  const userCardDeployerAddress = await userCardDeployer.getAddress();
  (out.contracts as Record<string, unknown>).beamioUserCardDeployer = { address: userCardDeployerAddress, tx: userCardDeployer.deploymentTransaction()?.hash };
  console.log("✅ BeamioUserCardDeployerV07:", userCardDeployerAddress);
  await verify(userCardDeployerAddress, [], "BeamioUserCardDeployerV07");
  await new Promise((r) => setTimeout(r, 3000));

  // ==================== 7. BeamioUserCardFactoryPaymasterV07 ====================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 7: 部署 BeamioUserCardFactoryPaymasterV07");
  console.log("=".repeat(60));
  const USER_CARD_METADATA_BASE_URI = "https://beamio.app/api/metadata/0x";
  const UserCardFactoryFactory = await ethers.getContractFactory("BeamioUserCardFactoryPaymasterV07");
  const userCardFactory = await UserCardFactoryFactory.deploy(
    USDC_ADDRESS,
    redeemModuleAddress,
    quoteHelperAddress,
    userCardDeployerAddress,
    aaFactoryAddress,
    deployer.address
  );
  await userCardFactory.waitForDeployment();
  const userCardFactoryAddress = await userCardFactory.getAddress();
  await (await userCardFactory.setMetadataBaseURI(USER_CARD_METADATA_BASE_URI)).wait();
  (out.contracts as Record<string, unknown>).beamioUserCardFactoryPaymaster = {
    address: userCardFactoryAddress,
    usdc: USDC_ADDRESS,
    redeemModule: redeemModuleAddress,
    quoteHelper: quoteHelperAddress,
    deployer: userCardDeployerAddress,
    aaFactory: aaFactoryAddress,
    metadataBaseURI: USER_CARD_METADATA_BASE_URI,
    tx: userCardFactory.deploymentTransaction()?.hash,
  };
  console.log("✅ BeamioUserCardFactoryPaymasterV07:", userCardFactoryAddress);
  await verify(userCardFactoryAddress, [USDC_ADDRESS, redeemModuleAddress, quoteHelperAddress, userCardDeployerAddress, aaFactoryAddress, deployer.address], "BeamioUserCardFactoryPaymasterV07");

  // UserCardDeployer 需设置 Factory（onlyOwner）
  console.log("设置 UserCardDeployer.setFactory(UserCardFactory)...");
  const txSetFactory = await userCardDeployer.setFactory(userCardFactoryAddress);
  await txSetFactory.wait();
  console.log("✅ UserCardDeployer.setFactory 已调用");

  // ==================== 8. BeamioUserCard ====================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 8: 部署 BeamioUserCard（gateway = AA Factory）");
  console.log("=".repeat(60));
  const USER_CARD_URI = process.env.USER_CARD_URI || "https://beamio.app/api/metadata/0x";
  const USER_CARD_CURRENCY = parseInt(process.env.USER_CARD_CURRENCY || "4"); // 4 = USDC
  const USER_CARD_PRICE = process.env.USER_CARD_PRICE || "1000000"; // pointsUnitPriceInCurrencyE6，1 USDC = 1e6
  const BeamioUserCardFactory = await ethers.getContractFactory("BeamioUserCard");
  const userCard = await BeamioUserCardFactory.deploy(USER_CARD_URI, USER_CARD_CURRENCY, USER_CARD_PRICE, deployer.address, aaFactoryAddress);
  await userCard.waitForDeployment();
  const userCardAddress = await userCard.getAddress();
  (out.contracts as Record<string, unknown>).beamioUserCard = {
    address: userCardAddress,
    uri: USER_CARD_URI,
    currency: USER_CARD_CURRENCY,
    price: USER_CARD_PRICE,
    gateway: aaFactoryAddress,
    tx: userCard.deploymentTransaction()?.hash,
  };
  console.log("✅ BeamioUserCard:", userCardAddress);
  await verify(userCardAddress, [USER_CARD_URI, USER_CARD_CURRENCY, USER_CARD_PRICE, deployer.address, aaFactoryAddress], "BeamioUserCard");
  await new Promise((r) => setTimeout(r, 3000));

  // ==================== 9. 更新 AA Factory 的 UserCard ====================
  console.log("\n" + "=".repeat(60));
  console.log("步骤 9: AA Factory.setUserCard(BeamioUserCard)");
  console.log("=".repeat(60));
  const currentUC = await aaFactory.beamioUserCard();
  if (currentUC.toLowerCase() !== userCardAddress.toLowerCase()) {
    const txUC = await aaFactory.setUserCard(userCardAddress);
    await txUC.wait();
    console.log("✅ setUserCard 已调用, tx:", txUC.hash);
  } else {
    console.log("✅ Factory 已指向该 UserCard");
  }

  // ==================== 保存 ====================
  const outFile = path.join(deploymentsDir, `${networkInfo.name}-FullAccountAndUserCard.json`);
  fs.writeFileSync(outFile, JSON.stringify(out, null, 2));
  console.log("\n" + "=".repeat(60));
  console.log("部署完成!");
  console.log("=".repeat(60));
  console.log("部署信息已保存:", outFile);
  console.log("\n📋 摘要:");
  console.log("  BeamioAccountDeployer:", accountDeployerAddress);
  console.log("  BeamioAccount:", beamioAccountAddress);
  console.log("  BeamioContainerModuleV07:", containerModuleAddress);
  console.log("  BeamioFactoryPaymasterV07 (AA Factory):", aaFactoryAddress);
  console.log("  BeamioUserCard:", userCardAddress);
  console.log("  BeamioUserCardFactoryPaymasterV07:", userCardFactoryAddress);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
