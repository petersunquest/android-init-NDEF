/**
 * 部署 ValidatorDepositRedeem 栈到 CoNET：
 *   1) ValidatorDepositRedeemStatsLib（link）
 *   2) ValidatorDepositRedeem
 *   3) ValidatorDepositRedeemReferrerExtension
 *   4) ValidatorDepositRedeemTransferMarket
 *   5) 连线 setRedeemHost / setReferrerExtension / setTransferMarket
 *
 * 运行:
 *   npx hardhat run scripts/deployValidatorDepositRedeemToConet.ts --network conet
 *
 * 部署后验证:
 *   npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import { mergeConetAdminPrivateKeysFromMasterFile } from "./utils/conetMasterAdmins.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

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
  console.log("Deploy ValidatorDepositRedeem stack on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  console.log("initialRedeemAdmin:", initialRedeemAdmin);
  console.log("initialContractAdmin (withdrawNative):", initialContractAdmin);
  console.log("gbToken (ConetGB1155):", gbToken);
  console.log("usdcToken (conetUsdc):", usdcToken);
  console.log("guardianNodes (GuardianNodesInfoV6):", guardianNodes);
  console.log("guardianAllocStartId:", guardianAllocStartId.toString());
  console.log("balance:", ethers.formatEther(await ethersHH.provider.getBalance(deployer.address)), "CNET\n");

  const StatsLibFactory = await ethersHH.getContractFactory("ValidatorDepositRedeemStatsLib");
  const statsLib = await StatsLibFactory.deploy();
  await statsLib.waitForDeployment();
  const statsLibAddr = await statsLib.getAddress();
  console.log("ValidatorDepositRedeemStatsLib:", statsLibAddr);

  const RedeemFactory = await ethersHH.getContractFactory("ValidatorDepositRedeem", {
    libraries: {
      ValidatorDepositRedeemStatsLib: statsLibAddr,
    },
  });
  const redeem = await RedeemFactory.deploy(
    initialRedeemAdmin,
    initialContractAdmin,
    gbToken,
    usdcToken,
    guardianNodes,
    guardianAllocStartId
  );
  await redeem.waitForDeployment();
  const redeemAddr = await redeem.getAddress();
  const redeemDeployTx = redeem.deploymentTransaction();
  const redeemTxHash = redeemDeployTx?.hash ?? "";
  let redeemDeployBlock = 0;
  if (redeemDeployTx) {
    const receipt = await redeemDeployTx.wait();
    redeemDeployBlock = Number(receipt?.blockNumber ?? 0);
  }
  console.log("ValidatorDepositRedeem:", redeemAddr);
  console.log("  tx:", redeemTxHash);
  if (redeemDeployBlock) console.log("  block:", redeemDeployBlock);

  const ExtFactory = await ethersHH.getContractFactory("ValidatorDepositRedeemReferrerExtension");
  const referrerExt = await ExtFactory.deploy(initialRedeemAdmin);
  await referrerExt.waitForDeployment();
  const referrerExtAddr = await referrerExt.getAddress();
  console.log("ValidatorDepositRedeemReferrerExtension:", referrerExtAddr);

  const MarketFactory = await ethersHH.getContractFactory("ValidatorDepositRedeemTransferMarket");
  const transferMarket = await MarketFactory.deploy(redeemAddr);
  await transferMarket.waitForDeployment();
  const transferMarketAddr = await transferMarket.getAddress();
  console.log("ValidatorDepositRedeemTransferMarket:", transferMarketAddr);

  const wireExt = await referrerExt.setRedeemHost(redeemAddr);
  await wireExt.wait();
  console.log("referrerExt.setRedeemHost ok");

  const wireRef = await redeem.setReferrerExtension(referrerExtAddr);
  await wireRef.wait();
  console.log("redeem.setReferrerExtension ok");

  const wireMarket = await redeem.setTransferMarket(transferMarketAddr);
  await wireMarket.wait();
  console.log("redeem.setTransferMarket ok");

  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "ValidatorDepositRedeem",
    source: "src/mainnet/ValidatorDepositRedeem.sol",
    address: redeemAddr,
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
    constructorArgs: {
      initialRedeemAdmin,
      initialContractAdmin,
      gbToken,
      usdcToken,
      guardianNodes,
      guardianAllocStartId: guardianAllocStartId.toString(),
    },
    libraryLinks: {
      ValidatorDepositRedeemStatsLib: statsLibAddr,
    },
    timestamp: new Date().toISOString(),
    deployBlock: redeemDeployBlock || undefined,
    transactionHash: redeemTxHash,
    contracts: {
      ValidatorDepositRedeemStatsLib: { address: statsLibAddr },
      ValidatorDepositRedeem: {
        address: redeemAddr,
        initialRedeemAdmin,
        initialContractAdmin,
        gbToken,
        usdcToken,
        guardianNodes,
        guardianAllocStartId: guardianAllocStartId.toString(),
        statsLib: statsLibAddr,
        referrerExtension: referrerExtAddr,
        transferMarket: transferMarketAddr,
        transactionHash: redeemTxHash,
      },
      ValidatorDepositRedeemReferrerExtension: {
        address: referrerExtAddr,
        admin: initialRedeemAdmin,
        redeemHost: redeemAddr,
      },
      ValidatorDepositRedeemTransferMarket: {
        address: transferMarketAddr,
        redeemHost: redeemAddr,
      },
    },
  };

  const outPath = path.join(deploymentsDir, "conet-ValidatorDepositRedeem.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("saved:", outPath);

  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  if (fs.existsSync(addrPath)) {
    const merged = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
    const prev = typeof merged.ValidatorDepositRedeem === "string" ? merged.ValidatorDepositRedeem : "";
    if (prev && prev !== redeemAddr) {
      const deprecated = Array.isArray(merged.DEPRECATED_VALIDATOR_DEPOSIT_REDEEM)
        ? (merged.DEPRECATED_VALIDATOR_DEPOSIT_REDEEM as string[])
        : [];
      if (!deprecated.includes(prev)) deprecated.push(prev);
      merged.DEPRECATED_VALIDATOR_DEPOSIT_REDEEM = deprecated;
    }
    merged.ValidatorDepositRedeem = redeemAddr;
    merged.ValidatorDepositRedeemStatsLib = statsLibAddr;
    merged.ValidatorDepositRedeemReferrerExtension = referrerExtAddr;
    merged.ValidatorDepositRedeemTransferMarket = transferMarketAddr;
    merged.validatorDepositRedeemDeployer = deployer.address;
    merged.validatorDepositContractAdmin = initialContractAdmin;
    merged.validatorDepositRedeemDeployedAt = new Date().toISOString();
    merged.validatorDepositRedeemTx = redeemTxHash;
    if (redeemDeployBlock) merged.validatorDepositRedeemDeployBlock = redeemDeployBlock;
    fs.writeFileSync(addrPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
    console.log("updated deployments/conet-addresses.json");
  }

  console.log("\n下一步（必须）: npx tsx scripts/verifyValidatorDepositRedeemStackConet.ts");
  console.log("配置 deposit / rewardIndexer: npx hardhat run scripts/configureValidatorDepositRedeemConet.ts --network conet");
  console.log("添加 validator 节点 redeem admin: npx hardhat run scripts/addValidatorDepositRedeemAdminConet.ts --network conet");
  console.log("然后: npx tsx scripts/updateConetReferences.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
