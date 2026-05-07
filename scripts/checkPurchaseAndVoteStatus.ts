/**
 * Check: 1) B-Unit balance on CoNET for user; 2) ConetTreasury Usdc2BUnit proposal/vote status for Base purchase tx
 * Run: npx hardhat run scripts/checkPurchaseAndVoteStatus.ts --network conet
 * Or: BASE_TX=0x... USER=0x... npx hardhat run scripts/checkPurchaseAndVoteStatus.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
function loadBUnitAirdrop(): string {
  if (!fs.existsSync(ADDR_PATH)) throw new Error("conet-addresses.json not found");
  const d = JSON.parse(fs.readFileSync(ADDR_PATH, "utf-8"));
  return d.BUnitAirdrop || "0xFd60936707cb4583c08D8AacBA19E4bfaEE446B8";
}
const ADDR_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");

const BASE_PURCHASE_TX = "0xebc5c4117fe7e7643676acf8f7a64a5f41a5e1bafee5dfebc410f6b2598ef3d2";
const USER = "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
const PURCHASE_USDC = 0.02;

function loadConetTreasury(): string {
  if (!fs.existsSync(ADDR_PATH)) throw new Error("conet-addresses.json not found");
  const d = JSON.parse(fs.readFileSync(ADDR_PATH, "utf-8"));
  return d.ConetTreasury || "0x540767C2a183871deb22333a271D5e65bF489F22";
}

async function main() {
  const baseTx = process.env.BASE_TX || BASE_PURCHASE_TX;
  const userRaw = process.env.CHECK_USER || process.env.USER_ADDR || USER;
  const user = userRaw.startsWith("0x") && userRaw.length === 42 ? userRaw : USER;

  const { ethers } = await networkModule.connect();
  const treasuryAddr = loadConetTreasury();

  console.log("=".repeat(60));
  console.log("Check B-Unit balance & ConetTreasury vote status");
  console.log("=".repeat(60));
  console.log("User:", user);
  console.log("Base purchase tx:", baseTx);
  console.log("Expected B-Unit from purchase:", PURCHASE_USDC, "(1 USDC = 100 B-Unit, 0.02 USDC = 2 B-Unit)");
  console.log();

  // 1. B-Unit balance on CoNET
  const airdropAddr = loadBUnitAirdrop();
  const airdrop = new ethers.Contract(
    airdropAddr,
    ["function getBUnitBalance(address) view returns (uint256)"],
    ethers.provider
  );
  const bal = await airdrop.getBUnitBalance(user);
  const balHuman = Number(ethers.formatUnits(bal, 6));
  console.log("[1] B-Unit balance on CoNET:", balHuman, "B-Units (raw:", bal.toString() + ")");
  if (balHuman >= PURCHASE_USDC * 100) {
    console.log("    ✅ Balance >= 2 B-Units (0.02 USDC purchase), node likely executed");
  } else {
    console.log("    ⚠️ Balance < 2 B-Units, node may not have voted/executed yet");
  }
  console.log();

  // 2. ConetTreasury Usdc2BUnit proposal
  const txHashBytes32 = baseTx.length === 66 ? baseTx as `0x${string}` : ethers.zeroPadValue(baseTx, 32);
  const treasury = new ethers.Contract(
    treasuryAddr,
    [
      "function getUsdc2BUnitProposal(bytes32 txHash) view returns (address user, uint256 usdcAmount, uint256 voteCount, bool executed)",
      "function requiredVotes() view returns (uint256)",
      "function minerCount() view returns (uint256)",
    ],
    ethers.provider
  );

  const [proposalUser, usdcAmount, voteCount, executed] = await treasury.getUsdc2BUnitProposal(txHashBytes32);
  const requiredVotes = await treasury.requiredVotes();
  const minerCount = await treasury.minerCount();

  console.log("[2] ConetTreasury Usdc2BUnit proposal (txHash = Base purchase tx):");
  console.log("    ConetTreasury:", treasuryAddr);
  console.log("    minerCount:", minerCount.toString(), "| requiredVotes:", requiredVotes.toString());
  console.log("    user:", proposalUser);
  console.log("    usdcAmount:", usdcAmount?.toString(), "(", ethers.formatUnits(usdcAmount || 0n, 6), "USDC)");
  console.log("    voteCount:", voteCount?.toString());
  console.log("    executed:", executed);

  if (proposalUser === ethers.ZeroAddress) {
    console.log("    ⚠️ No proposal found - miners have not voted yet");
  } else if (executed) {
    console.log("    ✅ Proposal executed - B-Units minted");
  } else {
    console.log("    ⏳ Proposal exists, voteCount:", voteCount?.toString(), "/", requiredVotes.toString());
  }
}

main().catch(console.error);
