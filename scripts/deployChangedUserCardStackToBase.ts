/**
 * Deploy only the changed UserCard stack contracts to Base:
 * - changed/new modules
 * - BeamioUserCardFactoryPaymasterV07
 *
 * Reuses the existing BeamioUserCardDeployerV07 when possible, then points it at
 * the new factory. Unchanged modules are reused from deployments/base-UserCardFactory.json.
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { execSync } from "child_process";
import { ethers as ethersJs } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const USER_CARD_METADATA_BASE_URI = "https://beamio.app/api/metadata/0x";

const MODULE = {
  REDEEM: 0,
  FAUCET: 1,
  ISSUED_NFT: 2,
  GOVERNANCE: 3,
  MEMBERSHIP_STATS: 4,
  CHARGE_REWARD: 5,
  STATS_QUERY: 254,
} as const;

type ExistingFactoryConfig = {
  contracts?: {
    beamioUserCardDeployer?: { address?: string };
    beamioUserCardFactoryPaymaster?: {
      address?: string;
      usdc?: string;
      redeemModule?: string;
      quoteHelper?: string;
      deployer?: string;
      aaFactory?: string;
      faucetModule?: string;
      governanceModule?: string;
      issuedNftModule?: string;
      membershipStatsModule?: string;
      adminStatsQueryModule?: string;
      chargeRewardModule?: string;
      metadataBaseURI?: string;
    };
  };
};

function loadSignerPk(): string {
  if (process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.trim()) {
    return process.env.PRIVATE_KEY.startsWith("0x") ? process.env.PRIVATE_KEY : `0x${process.env.PRIVATE_KEY}`;
  }

  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) {
    throw new Error("Missing PRIVATE_KEY and ~/.master.json");
  }
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk || typeof pk !== "string") {
    throw new Error("Missing PRIVATE_KEY and ~/.master.json settle_contractAdmin[0]");
  }
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

function readJson<T>(file: string): T {
  return JSON.parse(fs.readFileSync(file, "utf-8")) as T;
}

function writeJson(file: string, value: unknown): void {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf-8");
}

function mustAddress(value: unknown, label: string): string {
  if (typeof value !== "string") throw new Error(`Missing ${label}`);
  return ethersJs.getAddress(value);
}

async function ensureCode(provider: { getCode(address: string): Promise<string> }, address: string, label: string) {
  const code = await provider.getCode(address);
  if (code === "0x" || code === "0x0") throw new Error(`${label} has no code: ${address}`);
}

async function deployContract(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  signer: ethersJs.Signer,
  contractName: string,
  txOverrides: Record<string, bigint>,
  libraries?: Record<string, string>
): Promise<{ address: string; txHash?: string }> {
  const factory = libraries
    ? await ethers.getContractFactory(contractName, { libraries })
    : await ethers.getContractFactory(contractName);
  const contract = await factory.connect(signer).deploy(txOverrides);
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  const txHash = contract.deploymentTransaction()?.hash;
  console.log(`${contractName}: ${address}`);
  return { address, txHash };
}

async function useExistingOrDeploy(
  provider: { getCode(address: string): Promise<string> },
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  signer: ethersJs.Signer,
  envAddress: string | undefined,
  contractName: string,
  txOverrides: Record<string, bigint>,
  libraries?: Record<string, string>
): Promise<{ address: string; txHash?: string; reused?: boolean }> {
  if (envAddress && envAddress.trim()) {
    const address = ethersJs.getAddress(envAddress.trim());
    await ensureCode(provider, address, contractName);
    console.log(`${contractName}: ${address} (reused from env)`);
    return { address, reused: true };
  }
  return deployContract(ethers, signer, contractName, txOverrides, libraries);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;
  const networkInfo = await provider.getNetwork();
  if (Number(networkInfo.chainId) !== 8453) {
    throw new Error(`Expected Base mainnet chainId 8453, got ${networkInfo.chainId.toString()}`);
  }

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const configDir = path.join(__dirname, "..", "config");
  const factoryFile = path.join(deploymentsDir, "base-UserCardFactory.json");
  const modulesFile = path.join(deploymentsDir, "base-UserCardModules.json");
  const baseAddressesFile = path.join(configDir, "base-addresses.json");

  const previous = readJson<ExistingFactoryConfig>(factoryFile);
  const previousFactory = previous.contracts?.beamioUserCardFactoryPaymaster;
  if (!previousFactory) throw new Error("Missing deployments/base-UserCardFactory.json factory section");

  const pk = loadSignerPk();
  const signer = new ethersJs.NonceManager(new ethers.Wallet(pk, provider));
  const signerAddress = await signer.getAddress();

  const feeData = await provider.getFeeData();
  const txOverrides: Record<string, bigint> = {};
  if (feeData.maxFeePerGas) txOverrides.maxFeePerGas = feeData.maxFeePerGas * 2n;
  if (feeData.maxPriorityFeePerGas) txOverrides.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas * 2n;

  const usdc = mustAddress(process.env.USDC_ADDRESS || previousFactory.usdc || BASE_USDC, "USDC");
  const redeemModule = mustAddress(process.env.REDEEM_MODULE_ADDRESS || previousFactory.redeemModule, "RedeemModule");
  const faucetModule = mustAddress(process.env.FAUCET_MODULE_ADDRESS || previousFactory.faucetModule, "FaucetModule");
  const governanceModule = mustAddress(
    process.env.GOVERNANCE_MODULE_ADDRESS || previousFactory.governanceModule,
    "GovernanceModule"
  );
  const quoteHelper = mustAddress(process.env.QUOTE_HELPER_ADDRESS || previousFactory.quoteHelper, "QuoteHelper");
  const existingDeployer = mustAddress(
    process.env.USER_CARD_DEPLOYER_ADDRESS ||
      previousFactory.deployer ||
      previous.contracts?.beamioUserCardDeployer?.address,
    "BeamioUserCardDeployerV07"
  );

  const baseAddresses = fs.existsSync(baseAddressesFile) ? readJson<Record<string, unknown>>(baseAddressesFile) : {};
  const transferLib = mustAddress(baseAddresses.BEAMIO_USER_CARD_TRANSFER_LIB, "BEAMIO_USER_CARD_TRANSFER_LIB");
  const aaFactory = mustAddress(
    process.env.AA_FACTORY_ADDRESS || previousFactory.aaFactory || baseAddresses.AA_FACTORY,
    "AA_FACTORY"
  );

  await ensureCode(provider, redeemModule, "RedeemModule");
  await ensureCode(provider, faucetModule, "FaucetModule");
  await ensureCode(provider, governanceModule, "GovernanceModule");
  await ensureCode(provider, quoteHelper, "QuoteHelper");
  await ensureCode(provider, existingDeployer, "BeamioUserCardDeployerV07");
  await ensureCode(provider, aaFactory, "AA_FACTORY");
  await ensureCode(provider, transferLib, "BeamioUserCardTransferLib");

  const deployerAbi = [
    "function owner() view returns (address)",
    "function factory() view returns (address)",
    "function setFactory(address f) external",
  ];
  const deployer = new ethers.Contract(existingDeployer, deployerAbi, signer);
  const deployerOwner = (await deployer.owner()) as string;
  if (deployerOwner.toLowerCase() !== signerAddress.toLowerCase()) {
    throw new Error(`Signer is not BeamioUserCardDeployerV07 owner. owner=${deployerOwner}, signer=${signerAddress}`);
  }

  console.log("=".repeat(72));
  console.log("Deploy changed UserCard stack to Base");
  console.log("=".repeat(72));
  console.log("Signer:", signerAddress);
  console.log("Existing deployer:", existingDeployer);
  console.log("Reused RedeemModule:", redeemModule);
  console.log("Reused FaucetModule:", faucetModule);
  console.log("Reused GovernanceModule:", governanceModule);
  console.log("QuoteHelper:", quoteHelper);
  console.log("AA_FACTORY:", aaFactory);

  const issued = await useExistingOrDeploy(
    provider,
    ethers,
    signer,
    process.env.ISSUED_NFT_MODULE_ADDRESS,
    "BeamioUserCardIssuedNftModuleV1",
    txOverrides
  );
  const membershipStats = await useExistingOrDeploy(
    provider,
    ethers,
    signer,
    process.env.MEMBERSHIP_STATS_MODULE_ADDRESS,
    "BeamioUserCardMembershipStatsModuleV1",
    txOverrides
  );
  const adminStatsQuery = await useExistingOrDeploy(
    provider,
    ethers,
    signer,
    process.env.ADMIN_STATS_QUERY_MODULE_ADDRESS,
    "BeamioUserCardAdminStatsQueryModuleV1",
    txOverrides
  );
  const chargeReward = await useExistingOrDeploy(
    provider,
    ethers,
    signer,
    process.env.CHARGE_REWARD_MODULE_ADDRESS,
    "BeamioUserCardChargeRewardModuleV1",
    txOverrides,
    { BeamioUserCardTransferLib: transferLib }
  );

  const Factory = await ethers.getContractFactory("BeamioUserCardFactoryPaymasterV07");
  const factory = await Factory.connect(signer).deploy(
    usdc,
    redeemModule,
    quoteHelper,
    existingDeployer,
    aaFactory,
    signerAddress,
    txOverrides
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  const factoryTxHash = factory.deploymentTransaction()?.hash;
  console.log("BeamioUserCardFactoryPaymasterV07:", factoryAddress);

  await (await factory.setMetadataBaseURI(USER_CARD_METADATA_BASE_URI, txOverrides)).wait();
  await (
    await factory.setDefaultModules(
      [
        MODULE.REDEEM,
        MODULE.FAUCET,
        MODULE.ISSUED_NFT,
        MODULE.GOVERNANCE,
        MODULE.MEMBERSHIP_STATS,
        MODULE.STATS_QUERY,
        MODULE.CHARGE_REWARD,
      ],
      [
        redeemModule,
        faucetModule,
        issued.address,
        governanceModule,
        membershipStats.address,
        adminStatsQuery.address,
        chargeReward.address,
      ],
      txOverrides
    )
  ).wait();

  await (await deployer.setFactory(factoryAddress, txOverrides)).wait();

  const moduleChecks = await Promise.all([
    factory.defaultModule(MODULE.REDEEM),
    factory.defaultModule(MODULE.FAUCET),
    factory.defaultModule(MODULE.ISSUED_NFT),
    factory.defaultModule(MODULE.GOVERNANCE),
    factory.defaultModule(MODULE.MEMBERSHIP_STATS),
    factory.defaultModule(MODULE.STATS_QUERY),
    factory.defaultModule(MODULE.CHARGE_REWARD),
  ]);
  const expected = [
    redeemModule,
    faucetModule,
    issued.address,
    governanceModule,
    membershipStats.address,
    adminStatsQuery.address,
    chargeReward.address,
  ];
  for (let i = 0; i < expected.length; i++) {
    if (ethersJs.getAddress(moduleChecks[i]) !== ethersJs.getAddress(expected[i])) {
      throw new Error(`defaultModule check failed at index ${i}: ${moduleChecks[i]} != ${expected[i]}`);
    }
  }

  const deploymentInfo = {
    network: "base",
    chainId: networkInfo.chainId.toString(),
    deployer: signerAddress,
    timestamp: new Date().toISOString(),
    previous: {
      factory: previousFactory.address,
      issuedNftModule: previousFactory.issuedNftModule,
      membershipStatsModule: previousFactory.membershipStatsModule,
      adminStatsQueryModule: previousFactory.adminStatsQueryModule,
      chargeRewardModule: previousFactory.chargeRewardModule,
    },
    contracts: {
      beamioUserCardDeployer: {
        address: existingDeployer,
        reused: true,
      },
      beamioUserCardFactoryPaymaster: {
        address: factoryAddress,
        usdc,
        redeemModule,
        quoteHelper,
        deployer: existingDeployer,
        aaFactory,
        faucetModule,
        governanceModule,
        issuedNftModule: issued.address,
        membershipStatsModule: membershipStats.address,
        adminStatsQueryModule: adminStatsQuery.address,
        chargeRewardModule: chargeReward.address,
        metadataBaseURI: USER_CARD_METADATA_BASE_URI,
        owner: signerAddress,
        transactionHash: factoryTxHash,
      },
      changedModules: {
        issuedNftModule: issued,
        membershipStatsModule: membershipStats,
        adminStatsQueryModule: adminStatsQuery,
        chargeRewardModule: chargeReward,
      },
    },
  };

  writeJson(factoryFile, deploymentInfo);
  writeJson(modulesFile, {
    network: "base",
    chainId: networkInfo.chainId.toString(),
    timestamp: deploymentInfo.timestamp,
    signer: signerAddress,
    factory: factoryAddress,
    modules: {
      redeemModule,
      issuedNftModule: issued.address,
      faucetModule,
      governanceModule,
      membershipStatsModule: membershipStats.address,
      adminStatsQueryModule: adminStatsQuery.address,
      chargeRewardModule: chargeReward.address,
    },
    replaced: deploymentInfo.previous,
    checks: {
      defaultModuleRegistry: true,
      existingDeployerRepointed: true,
    },
  });

  baseAddresses.BASE_MAINNET_CHAIN_ID = baseAddresses.BASE_MAINNET_CHAIN_ID ?? 8453;
  baseAddresses.AA_FACTORY = aaFactory;
  baseAddresses.CARD_FACTORY = factoryAddress;
  writeJson(baseAddressesFile, baseAddresses);

  try {
    execSync("node scripts/writeBaseMainnetFactoriesMd.mjs", {
      cwd: path.join(__dirname, ".."),
      stdio: "inherit",
    });
  } catch (error) {
    console.warn("Skipping BASE_MAINNET_FACTORIES.md update:", error instanceof Error ? error.message : String(error));
  }

  console.log("=".repeat(72));
  console.log("Deployment complete");
  console.log("Factory:", factoryAddress);
  console.log("IssuedNftModule:", issued.address);
  console.log("MembershipStatsModule:", membershipStats.address);
  console.log("AdminStatsQueryModule:", adminStatsQuery.address);
  console.log("ChargeRewardModule:", chargeReward.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
