/**
 * Post-proxy-deploy migration:
 *   1) Copy redeem admins from deprecated canonical → new proxy
 *   2) Transfer native CNET balance from old → proxy (optional reserve for deposits)
 *
 * Run (after deployValidatorDepositRedeemProxyToConet.ts):
 *   npx hardhat run scripts/migrateValidatorDepositRedeemStackToProxyConet.ts --network conet
 *
 * Env:
 *   OLD_VALIDATOR_DEPOSIT_REDEEM=0x1488ED…  (default: last entry in DEPRECATED_VALIDATOR_DEPOSIT_REDEEM or deployment json previousCanonical)
 *   NEW_VALIDATOR_DEPOSIT_REDEEM=0x…         (default: conet-addresses.json)
 *   MIGRATE_REDEEM_ADMINS=0xA,0xB           optional extra admins to add on proxy
 *   SKIP_BALANCE_MIGRATE=1                    skip CNET transfer
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const KNOWN_REDEEM_ADMINS = [
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1",
  "0xE974c5d10cc36738bC2619FC73b075504D5c6d1E",
  "0x4728BEeFa5b68E87a611EEC6965f5C5f9b2D5060",
];

function loadAddresses(): Record<string, unknown> {
  const p = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(p)) throw new Error("缺少 deployments/conet-addresses.json");
  return JSON.parse(fs.readFileSync(p, "utf-8")) as Record<string, unknown>;
}

function loadNewProxy(addrData: Record<string, unknown>): string {
  const env = process.env.NEW_VALIDATOR_DEPOSIT_REDEEM?.trim();
  const raw = env || (typeof addrData.ValidatorDepositRedeem === "string" ? addrData.ValidatorDepositRedeem : "");
  if (!raw || !ethers.isAddress(raw)) throw new Error("无效 NEW_VALIDATOR_DEPOSIT_REDEEM / conet-addresses.json");
  return ethers.getAddress(raw);
}

function loadOldRedeem(addrData: Record<string, unknown>): string {
  const env = process.env.OLD_VALIDATOR_DEPOSIT_REDEEM?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);

  const deployPath = path.join(root, "deployments", "conet-ValidatorDepositRedeem.json");
  if (fs.existsSync(deployPath)) {
    const d = JSON.parse(fs.readFileSync(deployPath, "utf-8")) as { previousCanonical?: string };
    if (d.previousCanonical && ethers.isAddress(d.previousCanonical)) {
      return ethers.getAddress(d.previousCanonical);
    }
  }

  const deprecated = Array.isArray(addrData.DEPRECATED_VALIDATOR_DEPOSIT_REDEEM)
    ? (addrData.DEPRECATED_VALIDATOR_DEPOSIT_REDEEM as string[])
    : [];
  const last = deprecated[deprecated.length - 1]?.trim();
  if (last && ethers.isAddress(last)) return ethers.getAddress(last);

  return ethers.getAddress("0x1488ED35054f2Eb5301E1dC14Be3D9283d10B3B5");
}

function loadExtraAdmins(): string[] {
  const env = process.env.MIGRATE_REDEEM_ADMINS?.trim();
  const fromEnv = env
    ? env
        .split(/[\s,]+/)
        .map((a) => a.trim())
        .filter((a) => ethers.isAddress(a))
        .map((a) => ethers.getAddress(a))
    : [];
  return [...new Set([...KNOWN_REDEEM_ADMINS.map((a) => ethers.getAddress(a)), ...fromEnv])];
}

async function main() {
  const addrData = loadAddresses();
  const newAddr = loadNewProxy(addrData);
  const oldAddr = loadOldRedeem(addrData);

  if (oldAddr.toLowerCase() === newAddr.toLowerCase()) {
    throw new Error("Old and new ValidatorDepositRedeem addresses are the same");
  }

  const { ethers: ethersHH } = await networkModule.connect();
  const [signer] = await ethersHH.getSigners();
  const me = await signer.getAddress();

  const oldContract = await ethersHH.getContractAt(
    [
      "function admins(address) view returns (bool)",
      "function redeemAdmins(address) view returns (bool)",
      "function withdrawNative(address to, uint256 amount) external",
    ],
    oldAddr,
    signer
  );

  const newContract = await ethersHH.getContractAt(
    [
      "function redeemAdmins(address) view returns (bool)",
      "function addRedeemAdmin(address account) external",
      "function admins(address) view returns (bool)",
    ],
    newAddr,
    signer
  );

  console.log("=".repeat(60));
  console.log("Migrate ValidatorDepositRedeem stack → UUPS proxy");
  console.log("=".repeat(60));
  console.log("signer:", me);
  console.log("old:", oldAddr);
  console.log("new proxy:", newAddr);

  const iAmNewRedeemAdmin = await newContract.redeemAdmins(me);
  if (!iAmNewRedeemAdmin) {
    throw new Error(`Signer ${me} is not redeem admin on new proxy — cannot add admins`);
  }

  const candidates = loadExtraAdmins();
  for (const admin of candidates) {
    const onOld = await oldContract.redeemAdmins(admin).catch(() => false);
    const onNew = await newContract.redeemAdmins(admin);
    if (onNew) {
      console.log("redeem admin already on proxy:", admin);
      continue;
    }
    if (!onOld && admin.toLowerCase() !== me.toLowerCase()) {
      console.log("skip (not on old contract):", admin);
      continue;
    }
    console.log("addRedeemAdmin on proxy:", admin);
    const tx = await newContract.addRedeemAdmin(admin);
    console.log("  tx:", tx.hash);
    await tx.wait();
  }

  if (process.env.SKIP_BALANCE_MIGRATE === "1") {
    console.log("SKIP_BALANCE_MIGRATE=1 — skipping CNET transfer");
    return;
  }

  const isOldContractAdmin = await oldContract.admins(me);
  if (!isOldContractAdmin) {
    console.log("Signer is not contract admin on old redeem — skipping balance migration");
    return;
  }

  const provider = ethersHH.provider;
  const balance = await provider.getBalance(oldAddr);
  if (balance === 0n) {
    console.log("Old contract balance is 0 — nothing to migrate.");
    return;
  }

  console.log("Migrating CNET:", ethers.formatEther(balance));
  const tx = await oldContract.withdrawNative(newAddr, balance);
  console.log("withdrawNative tx:", tx.hash);
  await tx.wait();

  const newBal = await provider.getBalance(newAddr);
  const oldBal = await provider.getBalance(oldAddr);
  console.log("old balance after:", ethers.formatEther(oldBal), "CNET");
  console.log("proxy balance after:", ethers.formatEther(newBal), "CNET");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
