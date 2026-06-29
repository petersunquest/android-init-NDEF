/**
 * Deploy ValidatorDepositRedeem as UUPS upgradeable ERC1967 proxy on CoNET.
 *
 *   1) ValidatorDepositRedeemStatsLib
 *   2) ValidatorDepositRedeem implementation (UUPS)
 *   3) ERC1967Proxy(implementation, initialize(...))  ← canonical address
 *   4) ValidatorDepositRedeemReferrerExtension + setRedeemHost(proxy)
 *   5) ValidatorDepositRedeemTransferMarket(proxy) — immutable host
 *   6) ValidatorNodeRewardIndexer + setRewardIndexer on proxy
 *
 * Run:
 *   npx hardhat run scripts/deployValidatorDepositRedeemProxyToConet.ts --network conet
 *
 * Then:
 *   npx tsx scripts/migrateValidatorDepositRedeemStackToProxyConet.ts --network conet
 *   npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts
 *   npx tsx scripts/updateConetReferences.ts
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import ERC1967ProxyArtifact from "@openzeppelin/contracts/build/contracts/ERC1967Proxy.json" with { type: "json" };
import { mergeConetAdminPrivateKeysFromMasterFile } from "./utils/conetMasterAdmins.js";
import {
  deployValidatorDepositRedeemLibraries,
  VALIDATOR_DEPOSIT_REDEEM_LIBRARY_NAMES,
} from "./utils/validatorDepositRedeemLibraries.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");
const DEFAULT_DEPOSIT = "0x4242424242424242424242424242424242424242";

function loadInitialRedeemAdmin(): string | undefined {
  const env = process.env.VALIDATOR_DEPOSIT_REDEEM_INITIAL_ADMIN?.trim();
  if (env) return env;
  const pks = mergeConetAdminPrivateKeysFromMasterFile();
  if (!pks.length) return undefined;
  return new ethers.Wallet(pks[0]).address;
}

function loadInitialContractAdmin(deployer: string): string {
  const env = process.env.VALIDATOR_DEPOSIT_REDEEM_INITIAL_CONTRACT_ADMIN?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  return ethers.getAddress(deployer);
}

function loadConetAddresses(): Record<string, unknown> {
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) return {};
  try {
    return JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function loadGbTokenAddress(addrData: Record<string, unknown>): string {
  const env = process.env.CONET_GB1155?.trim();
  const raw = env || (typeof addrData.ConetGB1155 === "string" ? (addrData.ConetGB1155 as string) : "");
  return raw && ethers.isAddress(raw) ? ethers.getAddress(raw) : ethers.ZeroAddress;
}

function loadGuardianNodesAddress(addrData: Record<string, unknown>): string {
  const env = process.env.CONET_GUARDIAN_NODES_INFO_V6?.trim();
  const raw =
    env ||
    (typeof addrData.GuardianNodesInfoV6 === "string"
      ? (addrData.GuardianNodesInfoV6 as string)
      : typeof addrData.guardianNodesInfoV6 === "string"
        ? (addrData.guardianNodesInfoV6 as string)
        : "0xBC6b53065b5647261396d002bDBA0d3396E0722f");
  return raw && ethers.isAddress(raw) ? ethers.getAddress(raw) : ethers.ZeroAddress;
}

function loadGuardianAllocStartId(): bigint {
  const env = process.env.VALIDATOR_REDEEM_GUARDIAN_ALLOC_START_ID?.trim();
  if (env && /^\d+$/.test(env)) return BigInt(env);
  return 100n;
}

function loadUsdcTokenAddress(addrData: Record<string, unknown>): string {
  const env = process.env.CONET_USDC?.trim();
  const raw =
    env ||
    (typeof addrData["conet-USDC"] === "string"
      ? (addrData["conet-USDC"] as string)
      : typeof addrData.conetUsdc === "string"
        ? (addrData.conetUsdc as string)
        : "");
  return raw && ethers.isAddress(raw) ? ethers.getAddress(raw) : ethers.ZeroAddress;
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [deployer] = await ethersHH.getSigners();
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  const initialRedeemAdminRaw = loadInitialRedeemAdmin() || deployer.address;
  if (!ethers.isAddress(initialRedeemAdminRaw)) {
    throw new Error("VALIDATOR_DEPOSIT_REDEEM_INITIAL_ADMIN 不是有效地址");
  }
  const initialRedeemAdmin = ethers.getAddress(initialRedeemAdminRaw);
  const initialContractAdmin = loadInitialContractAdmin(deployer.address);

  const addrData = loadConetAddresses();
  const gbToken = loadGbTokenAddress(addrData);
  const usdcToken = loadUsdcTokenAddress(addrData);
  const guardianNodes = loadGuardianNodesAddress(addrData);
  const guardianAllocStartId = loadGuardianAllocStartId();

  console.log("=".repeat(60));
  console.log("Deploy ValidatorDepositRedeem UUPS proxy stack on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  console.log("initialRedeemAdmin:", initialRedeemAdmin);
  console.log("initialContractAdmin:", initialContractAdmin);
  console.log("gbToken:", gbToken);
  console.log("usdcToken:", usdcToken);
  console.log("guardianNodes:", guardianNodes);
  console.log("guardianAllocStartId:", guardianAllocStartId.toString());
  console.log("balance:", ethers.formatEther(await ethersHH.provider.getBalance(deployer.address)), "CNET\n");

  const libraryLinks = await deployValidatorDepositRedeemLibraries(ethersHH);
  const statsLibAddr = libraryLinks.ValidatorDepositRedeemStatsLib;

  const ImplFactory = await ethersHH.getContractFactory("ValidatorDepositRedeem", {
    libraries: libraryLinks,
  });
  const impl = await ImplFactory.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  const implTx = impl.deploymentTransaction()?.hash ?? "";
  console.log("ValidatorDepositRedeem implementation:", implAddr);
  if (implTx) console.log("  impl tx:", implTx);

  const initData = ImplFactory.interface.encodeFunctionData("initialize", [
    initialRedeemAdmin,
    initialContractAdmin,
    gbToken,
    usdcToken,
    guardianNodes,
    guardianAllocStartId,
  ]);

  const ProxyFactory = new ethers.ContractFactory(
    ERC1967ProxyArtifact.abi,
    ERC1967ProxyArtifact.bytecode,
    deployer
  );
  const proxy = await ProxyFactory.deploy(implAddr, initData);
  await proxy.waitForDeployment();
  const proxyAddr = await proxy.getAddress();
  const proxyDeployTx = proxy.deploymentTransaction();
  const proxyTxHash = proxyDeployTx?.hash ?? "";
  let proxyDeployBlock = 0;
  if (proxyDeployTx) {
    const receipt = await proxyDeployTx.wait();
    proxyDeployBlock = Number(receipt?.blockNumber ?? 0);
  }
  console.log("ValidatorDepositRedeem proxy (canonical):", proxyAddr);
  console.log("  proxy tx:", proxyTxHash);
  if (proxyDeployBlock) console.log("  proxy block:", proxyDeployBlock);

  const redeem = ImplFactory.attach(proxyAddr) as Awaited<ReturnType<typeof ImplFactory.deploy>>;

  const ExtFactory = await ethersHH.getContractFactory("ValidatorDepositRedeemReferrerExtension");
  const referrerExt = await ExtFactory.deploy(initialRedeemAdmin);
  await referrerExt.waitForDeployment();
  const referrerExtAddr = await referrerExt.getAddress();
  console.log("ValidatorDepositRedeemReferrerExtension:", referrerExtAddr);

  const MarketFactory = await ethersHH.getContractFactory("ValidatorDepositRedeemTransferMarket");
  const transferMarket = await MarketFactory.deploy(proxyAddr);
  await transferMarket.waitForDeployment();
  const transferMarketAddr = await transferMarket.getAddress();
  console.log("ValidatorDepositRedeemTransferMarket:", transferMarketAddr);

  const wireExtHost = await referrerExt.setRedeemHost(proxyAddr);
  await wireExtHost.wait();
  console.log("referrerExt.setRedeemHost(proxy) ok");

  const wireRef = await redeem.setReferrerExtension(referrerExtAddr);
  await wireRef.wait();
  console.log("redeem.setReferrerExtension ok");

  const wireMarket = await redeem.setTransferMarket(transferMarketAddr);
  await wireMarket.wait();
  console.log("redeem.setTransferMarket ok");

  const depositContract = (() => {
    const env = process.env.CONET_DEPOSIT_CONTRACT?.trim();
    const raw = env || DEFAULT_DEPOSIT;
    if (!ethers.isAddress(raw)) throw new Error("CONET_DEPOSIT_CONTRACT 无效");
    return ethers.getAddress(raw);
  })();
  const txDep = await redeem.setDepositContract(depositContract);
  await txDep.wait();
  console.log("redeem.setDepositContract ok →", depositContract);

  const IndexerFactory = await ethersHH.getContractFactory("ValidatorNodeRewardIndexer");
  const rewardIndexer = await IndexerFactory.deploy(initialRedeemAdmin, proxyAddr);
  await rewardIndexer.waitForDeployment();
  const rewardIndexerAddr = await rewardIndexer.getAddress();
  const rewardIndexerTx = rewardIndexer.deploymentTransaction()?.hash ?? "";
  console.log("ValidatorNodeRewardIndexer:", rewardIndexerAddr);
  if (rewardIndexerTx) console.log("  tx:", rewardIndexerTx);

  const txIdx = await redeem.setRewardIndexer(rewardIndexerAddr);
  await txIdx.wait();
  console.log("redeem.setRewardIndexer ok");

  const prevCanonical =
    typeof addrData.ValidatorDepositRedeem === "string" ? (addrData.ValidatorDepositRedeem as string) : "";

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "ValidatorDepositRedeem",
    upgradeable: true,
    proxyPattern: "ERC1967Proxy",
    source: "src/mainnet/ValidatorDepositRedeem.sol",
    address: proxyAddr,
    implementation: implAddr,
    deployer: deployer.address,
    initialRedeemAdmin,
    initialContractAdmin,
    gbToken,
    usdcToken,
    guardianNodes,
    guardianAllocStartId: guardianAllocStartId.toString(),
    statsLib: statsLibAddr,
    referrerExtension: referrerExtAddr,
    transferMarket: transferMarketAddr,
    rewardIndexer: rewardIndexerAddr,
    depositContract,
    initializeArgs: {
      initialRedeemAdmin,
      initialContractAdmin,
      gbToken,
      usdcToken,
      guardianNodes,
      guardianAllocStartId: guardianAllocStartId.toString(),
    },
    libraryLinks,
    timestamp: new Date().toISOString(),
    deployBlock: proxyDeployBlock || undefined,
    transactionHash: proxyTxHash,
    implementationTransactionHash: implTx || undefined,
    previousCanonical: prevCanonical || undefined,
    contracts: {
      ...Object.fromEntries(
        VALIDATOR_DEPOSIT_REDEEM_LIBRARY_NAMES.map((name) => [
          name,
          { address: libraryLinks[name] },
        ])
      ),
      ValidatorDepositRedeem: {
        implementation: implAddr,
        proxy: proxyAddr,
        address: proxyAddr,
        initialRedeemAdmin,
        initialContractAdmin,
        gbToken,
        usdcToken,
        guardianNodes,
        guardianAllocStartId: guardianAllocStartId.toString(),
        statsLib: statsLibAddr,
        referrerExtension: referrerExtAddr,
        transferMarket: transferMarketAddr,
        transactionHash: proxyTxHash,
      },
      ValidatorDepositRedeemReferrerExtension: {
        address: referrerExtAddr,
        admin: initialRedeemAdmin,
        redeemHost: proxyAddr,
      },
      ValidatorDepositRedeemTransferMarket: {
        address: transferMarketAddr,
        redeemHost: proxyAddr,
      },
      ValidatorNodeRewardIndexer: {
        address: rewardIndexerAddr,
        admin: initialRedeemAdmin,
        redeem: proxyAddr,
        transactionHash: rewardIndexerTx || undefined,
      },
    },
  };

  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const outPath = path.join(deploymentsDir, "conet-ValidatorDepositRedeem.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("saved:", outPath);

  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  if (fs.existsSync(addrPath)) {
    const merged = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
    const prev = typeof merged.ValidatorDepositRedeem === "string" ? merged.ValidatorDepositRedeem : "";
    if (prev && prev !== proxyAddr) {
      const deprecated = Array.isArray(merged.DEPRECATED_VALIDATOR_DEPOSIT_REDEEM)
        ? (merged.DEPRECATED_VALIDATOR_DEPOSIT_REDEEM as string[])
        : [];
      if (!deprecated.includes(prev)) deprecated.push(prev);
      merged.DEPRECATED_VALIDATOR_DEPOSIT_REDEEM = deprecated;
    }
    merged.ValidatorDepositRedeem = proxyAddr;
    merged.ValidatorDepositRedeemImplementation = implAddr;
    merged.ValidatorDepositRedeemStatsLib = statsLibAddr;
    for (const name of VALIDATOR_DEPOSIT_REDEEM_LIBRARY_NAMES) {
      merged[name] = libraryLinks[name];
    }
    merged.ValidatorDepositRedeemReferrerExtension = referrerExtAddr;
    merged.ValidatorDepositRedeemTransferMarket = transferMarketAddr;
    merged.ValidatorNodeRewardIndexer = rewardIndexerAddr;
    if (rewardIndexerTx) merged.validatorNodeRewardIndexerTx = rewardIndexerTx;
    merged.validatorNodeRewardIndexerConfiguredAt = new Date().toISOString();
    merged.validatorDepositRedeemDeployer = deployer.address;
    merged.validatorDepositContractAdmin = initialContractAdmin;
    merged.validatorDepositRedeemDeployedAt = new Date().toISOString();
    merged.validatorDepositRedeemTx = proxyTxHash;
    merged.validatorDepositRedeemUpgradeable = true;
    if (proxyDeployBlock) merged.validatorDepositRedeemDeployBlock = proxyDeployBlock;
    fs.writeFileSync(addrPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
    console.log("updated deployments/conet-addresses.json");
  }

  console.log("\n下一步:");
  console.log("  npx tsx scripts/migrateValidatorDepositRedeemStackToProxyConet.ts");
  console.log("  npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts");
  console.log("  npx tsx scripts/updateConetReferences.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
