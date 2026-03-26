/**
 * 部署「调试专用」BeamioUserCardFactoryPaymasterV07（含 DeployFailedCreateDebug 等最新源码），
 * 不覆盖 deployments/base-UserCardFactory.json。
 *
 * 必须部署新的 BeamioUserCardDeployerV07：链上旧 deployer 的 factory 固定为生产工厂，
 * 新工厂若复用旧 deployer 会 DEP_NotFactory。
 *
 * 依赖地址默认从 deployments/base-UserCardFactory.json + base-UserCardModules.json 读取（与生产一致）。
 *
 * 用法：
 *   npm run deploy:debug-usercard-factory:base
 *
 * 可选环境变量：
 *   DEBUG_AA_FACTORY=0x...   覆盖 aaFactory（默认与生产 json 一致；可设为 config 中 0x4b31… 做对齐试验）
 *   VERIFY=1                 部署后尝试 Basescan verify（需 BASESCAN_API_KEY）
 *   SKIP_BEAMIO_ACCOUNT_DEPLOYER_CHECK=1  跳过与 *-BeamioAccount.json deployer 的校验（默认会校验）
 *   ALLOW_MASTER_JSON_SIGNER=1            无 PRIVATE_KEY 时回退 ~/.master.json（与 deploy:base 不同，慎用）
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  ensureSignerMatchesBeamioAccountDeployerUnlessSkipped,
  getHardhatDeploySigner,
} from "./utils/hardhatDeploySigner.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const METADATA_BASE_URI = "https://beamio.app/api/metadata/0x";

async function main() {
  const { ethers } = await networkModule.connect();
  const deployer = await getHardhatDeploySigner(ethers);
  await ensureSignerMatchesBeamioAccountDeployerUnlessSkipped(ethers, deployer);

  const networkInfo = await ethers.provider.getNetwork();
  const name = networkInfo.name;
  const chainId = Number(networkInfo.chainId);
  if (chainId !== 8453 && chainId !== 84532) {
    console.warn("Unexpected chainId; intended for Base mainnet/sepolia. chainId=", chainId);
  }

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const prodFactoryFile = path.join(deploymentsDir, `${name}-UserCardFactory.json`);
  const modulesFile = path.join(deploymentsDir, `${name}-UserCardModules.json`);

  if (!fs.existsSync(prodFactoryFile)) {
    throw new Error(`Missing ${prodFactoryFile} (need production factory record for USDC/modules deps)`);
  }
  if (!fs.existsSync(modulesFile)) {
    throw new Error(`Missing ${modulesFile}`);
  }

  const prod = JSON.parse(fs.readFileSync(prodFactoryFile, "utf-8"));
  const c = prod.contracts?.beamioUserCardFactoryPaymaster;
  if (!c?.address) throw new Error("prod beamioUserCardFactoryPaymaster.address missing");

  const USDC = c.usdc;
  const REDEEM = c.redeemModule;
  const QUOTE = c.quoteHelper;
  const AA_FACTORY = (process.env.DEBUG_AA_FACTORY || c.aaFactory || "").trim();
  if (!ethers.isAddress(AA_FACTORY)) throw new Error("Invalid aaFactory; set DEBUG_AA_FACTORY or fix prod json");

  const modules = JSON.parse(fs.readFileSync(modulesFile, "utf-8")).modules;
  if (!modules) throw new Error("base-UserCardModules.json missing modules");

  const signerAddr = await deployer.getAddress();
  console.log("=".repeat(60));
  console.log("Deploy DEBUG UserCard factory (new deployer + new factory)");
  console.log("=".repeat(60));
  console.log("Signer:", signerAddr);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(signerAddr)), "ETH");
  console.log("USDC:", USDC);
  console.log("Redeem (ctor):", REDEEM);
  console.log("Quote:", QUOTE);
  console.log("AA Factory:", AA_FACTORY, process.env.DEBUG_AA_FACTORY ? "(DEBUG_AA_FACTORY)" : "(from prod json)");

  const feeData = await ethers.provider.getFeeData();
  const txO: { maxFeePerGas?: bigint; maxPriorityFeePerGas?: bigint } = {};
  if (feeData.maxFeePerGas) txO.maxFeePerGas = (feeData.maxFeePerGas * 3n) / 2n;
  if (feeData.maxPriorityFeePerGas) txO.maxPriorityFeePerGas = (feeData.maxPriorityFeePerGas * 3n) / 2n;

  console.log("\n1) BeamioUserCardDeployerV07...");
  const DeployerF = await ethers.getContractFactory("BeamioUserCardDeployerV07");
  const cardDeployer = await DeployerF.connect(deployer).deploy(txO);
  await cardDeployer.waitForDeployment();
  const deployerAddr = await cardDeployer.getAddress();
  console.log("   deployer:", deployerAddr);

  console.log("\n2) BeamioUserCardFactoryPaymasterV07...");
  const FactoryF = await ethers.getContractFactory("BeamioUserCardFactoryPaymasterV07");
  const factory = await FactoryF.connect(deployer).deploy(
    USDC,
    REDEEM,
    QUOTE,
    deployerAddr,
    AA_FACTORY,
    signerAddr,
    txO
  );
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("   factory:", factoryAddr);

  console.log("\n3) Link deployer -> factory...");
  await (await cardDeployer.connect(deployer).setFactory(factoryAddr, txO)).wait();

  console.log("\n4) setMetadataBaseURI + default modules (match prod modules file)...");
  await (await factory.connect(deployer).setMetadataBaseURI(METADATA_BASE_URI, txO)).wait();
  await (await factory.connect(deployer).setRedeemModule(modules.redeemModule, txO)).wait();
  await (await factory.connect(deployer).setIssuedNftModule(modules.issuedNftModule, txO)).wait();
  await (await factory.connect(deployer).setFaucetModule(modules.faucetModule, txO)).wait();
  await (await factory.connect(deployer).setGovernanceModule(modules.governanceModule, txO)).wait();
  await (await factory.connect(deployer).setMembershipStatsModule(modules.membershipStatsModule, txO)).wait();
  await (await factory.connect(deployer).setAdminStatsQueryModule(modules.adminStatsQueryModule, txO)).wait();

  const extraPm = (process.env.DEBUG_EXTRA_PAYMASTERS || "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => ethers.isAddress(s));
  for (const a of extraPm) {
    console.log("   changePaymasterStatus:", a, true);
    await (await factory.connect(deployer).changePaymasterStatus(a, true, txO)).wait();
  }

  const out = {
    network: name,
    chainId: networkInfo.chainId.toString(),
    purpose: "DEBUG_ONLY — do not replace production CARD_FACTORY without ops review",
    deployerSigner: signerAddr,
    timestamp: new Date().toISOString(),
    productionFactoryReference: c.address,
    contracts: {
      beamioUserCardDeployer: {
        address: deployerAddr,
        transactionHash: cardDeployer.deploymentTransaction()?.hash,
      },
      beamioUserCardFactoryPaymaster: {
        address: factoryAddr,
        usdc: USDC,
        redeemModule: REDEEM,
        quoteHelper: QUOTE,
        deployer: deployerAddr,
        aaFactory: AA_FACTORY,
        metadataBaseURI: METADATA_BASE_URI,
        owner: signerAddr,
        transactionHash: factory.deploymentTransaction()?.hash,
        modulesBoundFrom: path.basename(modulesFile),
      },
    },
  };

  const outPath = path.join(deploymentsDir, `${name}-UserCardFactory-DEBUG.json`);
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
  console.log("\n" + "=".repeat(60));
  console.log("Wrote", outPath);
  console.log("DEBUG CARD_FACTORY=", factoryAddr);
  console.log("Next: CARD_FACTORY=" + factoryAddr + " npm run create:debug-card:base");
  console.log("  or: CARD_FACTORY=" + factoryAddr + " npm run create:ccsa:base");
  console.log("=".repeat(60));

  if (process.env.VERIFY === "1") {
    const { verifyContract } = await import("./utils/verifyContract.js");
    await new Promise((r) => setTimeout(r, 8000));
    await verifyContract(deployerAddr, [], "BeamioUserCardDeployerV07");
    await verifyContract(
      factoryAddr,
      [USDC, REDEEM, QUOTE, deployerAddr, AA_FACTORY, signerAddr],
      "BeamioUserCardFactoryPaymasterV07"
    );
  }
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
