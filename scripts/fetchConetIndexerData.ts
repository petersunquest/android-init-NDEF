/**
 * 从 CoNET 主网 BeamioIndexerDiamond 获取当前存在的交易数据
 * 用法: npx hardhat run scripts/fetchConetIndexerData.ts --network conet
 */

import { network as networkModule } from "hardhat";
import { ethers } from "ethers";

const INDEXER = "0x0DBDF27E71f9c89353bC5e4dC27c9C5dAe0cc612";

// txCategory 常量映射（便于显示）
const TX_CATEGORY_LABELS: Record<string, string> = {
  [ethers.keccak256(ethers.toUtf8Bytes("merchant_pay:confirmed"))]: "merchant_pay:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("merchant_pay:tip_updated"))]: "merchant_pay:tip_updated",
  [ethers.keccak256(ethers.toUtf8Bytes("transfer_in:confirmed"))]: "transfer_in:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("transfer_out:confirmed"))]: "transfer_out:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("topup:confirmed"))]: "topup:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("internal_transfer:confirmed"))]: "internal_transfer:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("voucher_burn:confirmed"))]: "voucher_burn:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("request_create:confirmed"))]: "request_create:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("request_fulfilled:confirmed"))]: "request_fulfilled:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("request_expired:confirmed"))]: "request_expired:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("request_cancel:confirmed"))]: "request_cancel:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("beamio_usercard_mint:confirmed"))]: "beamio_usercard_mint:confirmed",
  [ethers.keccak256(ethers.toUtf8Bytes("usdcNewCard"))]: "usdcNewCard",
  [ethers.keccak256(ethers.toUtf8Bytes("usdcUpgradeNewCard"))]: "usdcUpgradeNewCard",
  [ethers.keccak256(ethers.toUtf8Bytes("usdcTopupCard"))]: "usdcTopupCard",
  [ethers.keccak256(ethers.toUtf8Bytes("newCard"))]: "newCard",
  [ethers.keccak256(ethers.toUtf8Bytes("upgradeNewCard"))]: "upgradeNewCard",
  [ethers.keccak256(ethers.toUtf8Bytes("topupCard"))]: "topupCard",
  [ethers.keccak256(ethers.toUtf8Bytes("redeemNewCard"))]: "redeemNewCard",
  [ethers.keccak256(ethers.toUtf8Bytes("redeemUpgradeNewCard"))]: "redeemUpgradeNewCard",
  [ethers.keccak256(ethers.toUtf8Bytes("redeemTopupCard"))]: "redeemTopupCard",
  [ethers.keccak256(ethers.toUtf8Bytes("cardmint:confirmed"))]: "cardmint:confirmed", // legacy
  [ethers.keccak256(ethers.toUtf8Bytes("buintClaim"))]: "buintClaim",
  [ethers.keccak256(ethers.toUtf8Bytes("buintUSDC"))]: "buintUSDC",
  [ethers.keccak256(ethers.toUtf8Bytes("buintBurn"))]: "buintBurn",
};

function txCategoryLabel(cat: string): string {
  return TX_CATEGORY_LABELS[cat] ?? cat.slice(0, 18) + "...";
}

const ABI = [
  "function getTransactionCount() view returns (uint256)",
  "function getLatestTransactionsPaged(uint256 offset, uint256 limit) view returns (uint256 total, tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)[] page)",
];

async function main() {
  const { ethers: eth } = await networkModule.connect();
  const indexer = new eth.Contract(INDEXER, ABI, eth.provider);

  const total = await indexer.getTransactionCount();
  console.log("=== BeamioIndexerDiamond 当前数据 (CoNET 主网) ===\n");
  console.log("RPC:", (eth.provider as ethers.UrlJsonRpcProvider).connection?.url ?? "hardhat conet");
  console.log("Indexer:", INDEXER);
  console.log("交易总数 (txCount):", total.toString());
  console.log("");

  if (total === 0n) {
    console.log("无交易记录。");
    return;
  }

  const limit = Number(total) > 100 ? 100 : Number(total);
  const [totalFiltered, page] = await indexer.getLatestTransactionsPaged(0, limit);

  console.log(`最新 ${limit} 条交易 (按 actionId 倒序):\n`);

  const rows: Array<{
    actionId: number;
    txCategory: string;
    chainId: string;
    payer: string;
    payee: string;
    amountFiat6: string;
    amountUSDC6: string;
    timestamp: string;
    txId: string;
  }> = [];

  for (let i = 0; i < page.length; i++) {
    const tx = page[i];
    if (!tx?.exists) continue;

    const actionId = Number(total) - 1 - i;
    const ts = tx.timestamp ? new Date(Number(tx.timestamp) * 1000).toISOString() : "-";

    rows.push({
      actionId,
      txCategory: txCategoryLabel(String(tx.txCategory)),
      chainId: String(tx.chainId),
      payer: String(tx.payer).slice(0, 10) + "…",
      payee: String(tx.payee).slice(0, 10) + "…",
      amountFiat6: String(tx.finalRequestAmountFiat6 ?? 0n),
      amountUSDC6: String(tx.finalRequestAmountUSDC6 ?? 0n),
      timestamp: ts,
      txId: String(tx.id).slice(0, 18) + "…",
    });
  }

  // 简单表格输出
  console.log(
    "actionId | txCategory                  | chainId | payer      | payee      | amountFiat6 | amountUSDC6 | timestamp"
  );
  console.log("-".repeat(140));

  for (const r of rows) {
    console.log(
      `${String(r.actionId).padStart(7)} | ${r.txCategory.padEnd(28)} | ${r.chainId.padStart(7)} | ${r.payer.padEnd(10)} | ${r.payee.padEnd(10)} | ${r.amountFiat6.padStart(11)} | ${r.amountUSDC6.padStart(11)} | ${r.timestamp}`
    );
  }

  // 按 txCategory 统计
  const byCategory: Record<string, number> = {};
  for (const tx of page) {
    if (!tx?.exists) continue;
    const cat = txCategoryLabel(String(tx.txCategory));
    byCategory[cat] = (byCategory[cat] ?? 0) + 1;
  }

  console.log("\n--- 本页 txCategory 分布 ---");
  for (const [cat, count] of Object.entries(byCategory).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${cat}: ${count}`);
  }
}

main().catch(console.error);
