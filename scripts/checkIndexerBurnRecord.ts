/**
 * 检查 consumeFromUser 焚烧是否已正确记账到 BeamioIndexerDiamond
 * 用法: npx hardhat run scripts/checkIndexerBurnRecord.ts --network conet
 * 可选: CHECK_USER=0x... BURN_TX=0x... npx hardhat run scripts/checkIndexerBurnRecord.ts --network conet
 */

import { network as networkModule } from "hardhat";
import { ethers } from "ethers";

const INDEXER = "0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe";
const BUINT = "0x4A3E59519eE72B9Dcf376f0617fF0a0a5a1ef879";
const BUNIT_AIRDROP = "0xa7410a532544aB7d1bA70701D9D0E389e4f4Cc1F";

const ABI = [
  "function getAccountTransactionsPaged(address account, uint256 offset, uint256 limit) view returns (tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)[] page)",
  "function getAccountActionCount(address account) view returns (uint256)",
  "function getTransactionCount() view returns (uint256)",
  "function getTransactionRecord(uint256 actionId) view returns (tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists) tx, tuple(address asset, uint256 amountE6, uint8 assetType, uint8 source, uint256 tokenId, uint8 itemCurrencyType, uint256 offsetInRequestCurrencyE6)[] route)",
];

const TX_BUINT_BURN = ethers.keccak256(ethers.toUtf8Bytes("buintBurn"));

async function main() {
  const user = process.env.CHECK_USER || "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
  const burnTxHash = process.env.BURN_TX || "0x795f5626e33ba7f1e89d5c2072465bb1f52b593610696f24ab8f78ba04947e7e";

  const { ethers: eth } = await networkModule.connect();
  const indexer = new eth.Contract(INDEXER, ABI, eth.provider);

  // 1. Check consume tx for IndexerSyncFailed
  console.log("=".repeat(60));
  console.log("Check consumeFromUser Indexer Sync");
  console.log("=".repeat(60));
  const receipt = await eth.provider.getTransactionReceipt(burnTxHash);
  if (receipt) {
    console.log("consume tx block:", receipt.blockNumber, "logs:", receipt.logs.length);
    console.log("All log addresses:", [...new Set(receipt.logs.map((l) => l.address))]);
    console.log("All log topic0:", [...new Set(receipt.logs.map((l) => l.topics[0]))]);
    const indexerSyncTopic = eth.id("IndexerSyncFailed(bytes32,string)");
    const consumedTopic = eth.id("ConsumedAndAirdropped(address,uint256,uint256,bytes32,uint256,uint256)");
    const recordSyncedTopic = eth.id("TransactionRecordSynced(uint256,bytes32,bytes32,address,address)");
    const failedLogs = receipt.logs.filter(
      (l) => l.address.toLowerCase() === BUNIT_AIRDROP.toLowerCase() && l.topics[0] === indexerSyncTopic
    );
    const consumedLogs = receipt.logs.filter(
      (l) => l.address.toLowerCase() === BUNIT_AIRDROP.toLowerCase() && l.topics[0] === consumedTopic
    );
    const indexerLogs = receipt.logs.filter(
      (l) => l.address.toLowerCase() === INDEXER.toLowerCase() && l.topics[0] === recordSyncedTopic
    );
    if (consumedLogs.length > 0) {
      console.log("✅ ConsumedAndAirdropped 已发射 (consume 成功)");
    }
    if (indexerLogs.length > 0) {
      console.log("✅ Indexer TransactionRecordSynced 已发射", indexerLogs.length, "次 - syncTokenAction 成功");
      for (const l of indexerLogs) {
        const payer = "0x" + (l.topics[3]?.slice(26) || "").padStart(40, "0");
        const payee = "0x" + (l.data?.slice(90, 130) || "").padStart(40, "0");
        console.log("  payer:", payer, "payee:", payee);
      }
    }
    if (failedLogs.length > 0) {
      console.log("❌ IndexerSyncFailed 已发射 - 记账失败");
    } else if (indexerLogs.length === 0) {
      console.log("⚠️ Indexer TransactionRecordSynced 未发射 - syncTokenAction 可能未执行或失败被吞");
    }
  } else {
    console.log("(tx not found, skipping event check)");
  }

  // 2. Query user's transactions
  console.log("\n用户", user, "在 Indexer 中的交易:");
  const total = await indexer.getAccountActionCount(user);
  console.log("总数:", total.toString());

  const page = await indexer.getAccountTransactionsPaged(user, 0, 20);
  const burnRecords: unknown[] = [];
  const TX_BUINT_USDC = eth.keccak256(eth.toUtf8Bytes("buintUSDC"));
  const TX_SEND = eth.keccak256(eth.toUtf8Bytes("send"));
  for (const tx of page) {
    if (!tx?.exists) continue;
    const cat = tx.txCategory;
    const isBurn = cat === TX_BUINT_BURN;
    const isUsdc = cat === TX_BUINT_USDC;
    const isSend = cat === TX_SEND;
    if (isBurn || isSend) burnRecords.push(tx);
    const catLabel = isBurn ? "buintBurn" : isUsdc ? "buintUSDC" : isSend ? "send" : "other";
    const hashStr = tx.originalPaymentHash && tx.originalPaymentHash !== eth.ZeroHash ? tx.originalPaymentHash : "(zero)";
    console.log(
      `  - ${catLabel} txCategory=0x${typeof cat === "string" ? cat.slice(2) : ""} payer=${tx.payer} payee=${tx.payee} amount=${tx.finalRequestAmountFiat6?.toString()} paidUSDC6=${tx.finalRequestAmountUSDC6?.toString()} originalPaymentHash=${hashStr} ts=${tx.timestamp}`
    );
  }

  // 3. Also check BUint (payee) for burn records
  console.log("\nBUint (payee)", BUINT, "在 Indexer 中的交易:");
  const bunitTotal = await indexer.getAccountActionCount(BUINT);
  console.log("总数:", bunitTotal.toString());
  const bunitPage = await indexer.getAccountTransactionsPaged(BUINT, 0, 20);
  for (const tx of bunitPage) {
    if (!tx?.exists) continue;
    const isBurn = tx.txCategory === TX_BUINT_BURN && tx.payer === user;
    if (isBurn) {
      console.log("  - buintBurn (payer=user) amount=", tx.finalRequestAmountFiat6?.toString(), "paidUSDC6=", tx.finalRequestAmountUSDC6?.toString());
    }
  }

  // 4. Scan ALL transactions for burn (payer=user, payee=BUint) or send
  const totalTx = await indexer.getTransactionCount();
  console.log("\nIndexer 全局交易总数:", totalTx.toString());
  const burnMatches: { actionId: number; rec: { payer: string; payee: string; finalRequestAmountFiat6: bigint; finalRequestAmountUSDC6: bigint; timestamp: number; txCategory: string; originalPaymentHash?: string } }[] = [];
  for (let i = 0; i < Number(totalTx); i++) {
    const [rec] = await indexer.getTransactionRecord(i);
    if (!rec?.exists) continue;
    const isBurn =
      String(rec.payer).toLowerCase() === user.toLowerCase() &&
      String(rec.payee).toLowerCase() === BUINT.toLowerCase();
    const catMatch = rec.txCategory === TX_BUINT_BURN || rec.txCategory === TX_SEND;
    if (isBurn || catMatch) {
      burnMatches.push({ actionId: i, rec });
    }
  }
  if (burnMatches.length > 0) {
    console.log("找到 burn 记录:");
    const expectedHash = process.env.EXPECTED_HASH as string | undefined;
    let allHaveHash = true;
    for (const m of burnMatches) {
      const rec = m.rec as { originalPaymentHash?: string };
      const hashStr = rec.originalPaymentHash && rec.originalPaymentHash !== eth.ZeroHash ? rec.originalPaymentHash : "(zero)";
      const hasExpected = expectedHash && rec.originalPaymentHash?.toLowerCase() === expectedHash.toLowerCase();
      if (expectedHash && !hasExpected) allHaveHash = false;
      console.log(
        `  actionId=${m.actionId} payer=${m.rec.payer} payee=${m.rec.payee} amount=${m.rec.finalRequestAmountFiat6} paidUSDC6=${m.rec.finalRequestAmountUSDC6} originalPaymentHash=${hashStr}${hasExpected ? " ✅" : ""} ts=${m.rec.timestamp}`
      );
    }
    if (expectedHash) {
      console.log(allHaveHash ? "\n✅ 所有 burn 记录均带 expected hash" : "\n❌ 部分 burn 记录未带 expected hash");
    }
  } else {
    console.log("未找到任何 burn 记录 (payer=user, payee=BUint 或 txCategory=buintBurn)");
  }

  console.log("\nbuintBurn 记录数 (user as payer):", burnRecords.length);
  if (burnRecords.length === 0) {
    console.log("❌ 未找到 buintBurn 记账，可能 syncTokenAction 失败或尚未同步");
  } else {
    console.log("✅ buintBurn 记账正常");
  }
}

main().catch(console.error);
