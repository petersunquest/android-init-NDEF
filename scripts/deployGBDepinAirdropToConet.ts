/**
 * Deploy GBDepinAirdrop on CoNET mainnet and wire GBToken admin.
 *
 * Prerequisite: GBToken proxy must already be **V2** (consumeGb / mintPaid split pools).
 *
 * Run:
 *   npx hardhat run scripts/deployGBDepinAirdropToConet.ts --network conet
 *
 * Env (optional):
 *   GB_TOKEN_ERC20 — override GBToken proxy address
 *   VDR_ADDRESS — ValidatorDepositRedeem proxy
 *   GUARDIAN_NODES — GuardianNodesInfoV6
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const MASTER_PATH = path.join(homedir(), ".master.json");

const DEFAULT_GB_TOKEN = "0xC3EF02DaE632b4C10abB66e07d92a387c10838D8";
const DEFAULT_VDR = "0xc71e246DD78B37C2fABc905D340932F28F503433";
const DEFAULT_GUARDIAN = "0xBC6b53065b5647261396d002bDBA0d3396E0722f";

function loadAddressesJson(): Record<string, unknown> {
  if (!fs.existsSync(ADDRESSES_PATH)) return {};
  return JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
}

function loadSettleAdmins(): string[] {
  if (!fs.existsSync(MASTER_PATH)) return [];
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const arr = data?.settle_contractAdmin || [];
  return arr.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`));
}

async function main() {
  const addrJson = loadAddressesJson();
  const gbToken =
    process.env.GB_TOKEN_ERC20 ||
    (addrJson.GBToken as string) ||
    (addrJson.contracts as { gbErc20?: { address?: string } })?.gbErc20?.address ||
    DEFAULT_GB_TOKEN;
  const vdr =
    process.env.VDR_ADDRESS ||
    (addrJson.ValidatorDepositRedeem as string) ||
    DEFAULT_VDR;
  const guardian =
    process.env.GUARDIAN_NODES ||
    (addrJson.GuardianNodesInfoV6 as string) ||
    DEFAULT_GUARDIAN;

  const settlePks = loadSettleAdmins();
  const { ethers } = await networkModule.connect();
  const settleAddresses = settlePks.map((pk: string) => new ethers.Wallet(pk).address);
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("Deploy GBDepinAirdrop on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("GBToken:", gbToken);
  console.log("ValidatorDepositRedeem:", vdr);
  console.log("GuardianNodesInfoV6:", guardian);
  console.log("chainId:", net.chainId.toString());

  const Factory = await ethers.getContractFactory("GBDepinAirdrop");
  const airdrop = await Factory.deploy(gbToken, deployer.address);
  await airdrop.waitForDeployment();
  const airdropAddress = await airdrop.getAddress();
  console.log("[1] GBDepinAirdrop deployed:", airdropAddress);

  const txCfg1 = await airdrop.setValidatorDepositRedeem(vdr);
  await txCfg1.wait();
  console.log("[2] setValidatorDepositRedeem ok");

  const txCfg2 = await airdrop.setGuardianNodes(guardian);
  await txCfg2.wait();
  console.log("[3] setGuardianNodes ok");

  const vdrContract = await ethers.getContractAt(
    ["function setGbDepinAirdrop(address) external"],
    vdr,
  );
  try {
    const txVdr = await vdrContract.setGbDepinAirdrop(airdropAddress);
    await txVdr.wait();
    console.log("[3b] ValidatorDepositRedeem.setGbDepinAirdrop ok");
  } catch (e) {
    console.warn(
      "[3b] setGbDepinAirdrop skipped (upgrade ValidatorDepositRedeem first):",
      (e as Error).message,
    );
  }

  const gb = await ethers.getContractAt("GBTokenV2", gbToken);
  if (!gb.interface.getFunction("consumeGb")) {
    throw new Error("GBToken proxy is not V2 (missing consumeGb); run upgradeGBTokenV2Conet.ts first");
  }
  console.log("[4a] GBToken V2 consumeGb confirmed");

  const txAdmin = await gb.addAdmin(airdropAddress);
  await txAdmin.wait();
  console.log("[4] GBToken.addAdmin(airdrop) ok");

  for (const addr of settleAddresses) {
    const txAdminDepin = await airdrop.addAdmin(addr);
    await txAdminDepin.wait();
    console.log("[5] GBDepinAirdrop.addAdmin(", addr, ") ok");
    const txSettler = await airdrop.addGbSettler(addr);
    await txSettler.wait();
    console.log("[5b] GBDepinAirdrop.addGbSettler(", addr, ") ok");
  }

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      GBToken: { address: gbToken },
      ValidatorDepositRedeem: { address: vdr },
      GuardianNodesInfoV6: { address: guardian },
      GBDepinAirdrop: {
        address: airdropAddress,
        monthlyPaidGbPerNode: "3000e9",
        freeClaimAmount: "10e9",
        freeClaimIntervalSeconds: 86400,
        admins: settleAddresses,
        gbSettlers: settleAddresses,
      },
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-GBDepinAirdrop.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\n[6] saved:", outPath);

  const merged = { ...addrJson, GBDepinAirdrop: airdropAddress };
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(merged, null, 2) + "\n", "utf-8");
  console.log("[7] updated conet-addresses.json GBDepinAirdrop:", airdropAddress);

  syncGbDepinAirdropAddressToClients(airdropAddress);

  console.log("\nPaid DePIN airdrop (30-day month, per-second rate):");
  console.log("  perSecond = monthlyPaidGbPerNode / (30*24*60*60)");
  console.log("  airdropDepinPaidAll() — mint = perSecond * (now - lastDepinPaidCallAt) per node");
  console.log("  mid-period new nodes: register only, no backfill on first sight");
  console.log("  airdropDepinPaidPage(start,len,true) — paginated; advance clock on last page only");
  console.log("\nUser bandwidth fee (GBToken V2 consumeGb + on-chain ledger):");
  console.log("  chargeUserGbForGuardianNode(nodeId, user, amount) — consumeGb + beneficiaryPaidGbTotal");
  console.log("  UI: paidGbReceivedOf(beneficiary) / paidGbReceivedOfGuardianNode(nodeId)");
  console.log("  addGbSettler(<Master gateway>) for API-driven charges");
  console.log("\nAPI (Cluster → Master):");
  console.log("  POST /api/gbDepinChargeUserGb { guardianNodeId, user, amount }");
  console.log("  POST /api/gbDepinAirdropPaidAll {}");
  console.log("  Master cron: CONET_GB_DEPIN_AIRDROP=<addr> CONET_GB_DEPIN_AIRDROP_CRON=1");
}

function syncGbDepinAirdropAddressToClients(airdropAddress: string): void {
  const root = path.join(__dirname, "..");
  const x402Path = path.join(root, "src", "x402sdk", "src", "chainAddresses.ts");
  const uiPath = path.join(root, "src", "SilentPassUI", "src", "config", "chainAddresses.ts");
  const line = `export const CONET_GB_DEPIN_AIRDROP = '${airdropAddress}'`;
  for (const filePath of [x402Path, uiPath]) {
    if (!fs.existsSync(filePath)) continue;
    let src = fs.readFileSync(filePath, "utf-8");
    if (/export const CONET_GB_DEPIN_AIRDROP\s*=/.test(src)) {
      src = src.replace(/export const CONET_GB_DEPIN_AIRDROP\s*=\s*'[^']*'/, line);
      src = src.replace(
        /export const CONET_GB_DEPIN_AIRDROP\s*=\s*process\.env\.CONET_GB_DEPIN_AIRDROP\?\.trim\(\)\s*\|\|\s*''/,
        line,
      );
    } else {
      src = src.replace(/(export const CONET_GB_DECIMALS = 9\n)/, `$1${line}\n`);
    }
    fs.writeFileSync(filePath, src, "utf-8");
    console.log("[8] synced CONET_GB_DEPIN_AIRDROP →", filePath);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
