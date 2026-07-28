/**
 * 检查指定账户在 BeamioIndexerDiamond 中是否有 buintClaim 记录
 * 用法: npx hardhat run scripts/checkIndexerClaimRecord.ts --network conet
 */

import { network as networkModule } from "hardhat";
import { ethers } from "ethers";

const INDEXER = "0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe";
const TX_BUINT_CLAIM = ethers.keccak256(ethers.toUtf8Bytes("buintClaim"));
const TX_BUINT_USDC = ethers.keccak256(ethers.toUtf8Bytes("buintUSDC"));
const TX_BUINT_BURN = ethers.keccak256(ethers.toUtf8Bytes("buintBurn"));
const BUINT = "0xC97CEbb4DF827cB2D1453A9Df7FEf6dADa1C16Ad";

const ABI = [
  "function getAccountTransactionsPaged(address account, uint256 offset, uint256 limit) view returns ((bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)[] page)",
  "function getAccountActionCount(address account) view returns (uint256)",
];

async function main() {
  const account = process.env.CLAIMANT || process.env.CHECK_USER || "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
  const { ethers: eth } = await networkModule.connect();
  const indexer = new eth.Contract(INDEXER, ABI, eth.provider);

  const total = await indexer.getAccountActionCount(account);
  console.log("账户", account, "在 Indexer 中的交易总数:", total.toString());

  const page = await indexer.getAccountTransactionsPaged(account, 0, 50);
  console.log("全部记录 (共", page.filter((t: { exists: boolean }) => t?.exists).length, "条):");
  for (const tx of page) {
    if (!tx?.exists) continue;
    const cat = String(tx.txCategory);
    const catLabel = cat === TX_BUINT_CLAIM ? "buintClaim" : cat === TX_BUINT_USDC ? "buintUSDC" : cat === TX_BUINT_BURN ? "buintBurn" : "other";
    console.log("  -", catLabel, "payee:", tx.payee, "amount:", tx.finalRequestAmountFiat6?.toString(), "ts:", tx.timestamp?.toString());
  }
  const claimRecords = page.filter((tx: { exists: boolean; txCategory: string; payee: string }) => {
    if (!tx?.exists) return false;
    return String(tx.txCategory) === TX_BUINT_CLAIM && String(tx.payee).toLowerCase() === account.toLowerCase();
  });
  console.log("\nbuintClaim 记录数:", claimRecords.length);
}

main().catch(console.error);
