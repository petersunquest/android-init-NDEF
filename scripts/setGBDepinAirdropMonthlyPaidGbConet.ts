/**
 * Set GBDepinAirdrop.monthlyPaidGbPerNode on CoNET (admin tx).
 *
 *   npx hardhat run scripts/setGBDepinAirdropMonthlyPaidGbConet.ts --network conet
 *
 * Env:
 *   GB_DEPIN_AIRDROP — contract address (default deployments/conet-GBDepinAirdrop.json)
 *   MONTHLY_PAID_GB  — human GB amount (default 3000)
 *   DRY_RUN=1        — read-only, no tx
 */

import { network } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEPLOY_PATH = path.join(__dirname, "../deployments/conet-GBDepinAirdrop.json");
const GB_UNIT = 1_000_000_000n;

function resolveAirdropAddress(): string {
  if (process.env.GB_DEPIN_AIRDROP) return process.env.GB_DEPIN_AIRDROP;
  const j = JSON.parse(fs.readFileSync(DEPLOY_PATH, "utf-8")) as {
    contracts?: { GBDepinAirdrop?: { address?: string } };
  };
  const addr = j.contracts?.GBDepinAirdrop?.address;
  if (!addr) throw new Error("Missing GBDepinAirdrop address in deployments/conet-GBDepinAirdrop.json");
  return addr;
}

function resolveMonthlyGb(): bigint {
  const raw = process.env.MONTHLY_PAID_GB ?? "3000";
  const n = BigInt(raw);
  if (n <= 0n) throw new Error("MONTHLY_PAID_GB must be positive");
  return n * GB_UNIT;
}

async function main() {
  const airdropAddr = resolveAirdropAddress();
  const targetRaw = resolveMonthlyGb();
  const { ethers } = await network.connect();
  const airdrop = await ethers.getContractAt("GBDepinAirdrop", airdropAddr);

  const current = await airdrop.monthlyPaidGbPerNode();
  const perSecondBefore = await airdrop.paidGbPerSecond();
  console.log("GBDepinAirdrop:", airdropAddr);
  console.log("current monthlyPaidGbPerNode:", current.toString(), `(${(Number(current) / 1e9).toFixed(0)} GB)`);
  console.log("target monthlyPaidGbPerNode:", targetRaw.toString(), `(${(Number(targetRaw) / 1e9).toFixed(0)} GB)`);
  console.log("paidGbPerSecond (before):", perSecondBefore.toString());

  if (current === targetRaw) {
    console.log("✅ Already at target — no tx needed.");
    return;
  }

  if (process.env.DRY_RUN === "1") {
    console.log("DRY_RUN=1 — skipping setMonthlyPaidGbPerNode tx.");
    return;
  }

  const masterPath = path.join(homedir(), ".master.json");
  const master = JSON.parse(fs.readFileSync(masterPath, "utf-8")) as { settle_contractAdmin?: string[] };
  const pk = master.settle_contractAdmin?.[0];
  if (!pk) throw new Error("no settle_contractAdmin[0] in ~/.master.json");
  const wallet = new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`, ethers.provider);
  console.log("signer:", wallet.address);

  const c = airdrop.connect(wallet);
  const tx = await c.setMonthlyPaidGbPerNode(targetRaw);
  console.log("tx:", tx.hash);
  await tx.wait();

  const updated = await airdrop.monthlyPaidGbPerNode();
  const perSecondAfter = await airdrop.paidGbPerSecond();
  console.log("updated monthlyPaidGbPerNode:", updated.toString());
  console.log("paidGbPerSecond (after):", perSecondAfter.toString());
  console.log("✅ Done");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
