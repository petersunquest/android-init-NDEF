/**
 * 从 CoNET Indexer 拉取指定账户的原始账本，检查 originalPaymentHash 等字段
 * 用法: npx hardhat run scripts/checkBUnitLedgerRaw.ts --network conet
 * 可选: CHECK_ACCOUNT=0x... npx hardhat run scripts/checkBUnitLedgerRaw.ts --network conet
 */

import { network as networkModule } from "hardhat";
import { ethers } from "ethers";

const INDEXER = "0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe";
const BUINT = "0x4A3E59519eE72B9Dcf376f0617fF0a0a5a1ef879";

const ABI = [
  "function getAccountTransactionsPaged(address account, uint256 offset, uint256 limit) view returns (tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)[] page)",
];

const TX_REQUEST_ACCOUNTING = ethers.keccak256(ethers.toUtf8Bytes("requestAccounting"));
const TX_SEND_USDC = ethers.keccak256(ethers.toUtf8Bytes("sendUSDC"));
const TX_X402_SEND = ethers.keccak256(ethers.toUtf8Bytes("x402Send"));

async function main() {
  const account = process.env.CHECK_ACCOUNT || "0x513087820Af94A7f4d21bC5B68090f3080022E0e";

  const { ethers: eth } = await networkModule.connect();
  const indexer = new eth.Contract(INDEXER, ABI, eth.provider);

  console.log("=".repeat(70));
  console.log("CoNET Indexer 原始账本查询");
  console.log("账户:", account);
  console.log("=".repeat(70));

  const page = await indexer.getAccountTransactionsPaged(account, 0, 50);

  const accountLower = account.toLowerCase();
  const buintLower = BUINT.toLowerCase();

  console.log("\n总记录数:", page.length);

  let burnCount = 0;
  for (let i = 0; i < page.length; i++) {
    const tx = page[i];
    if (!tx?.exists) continue;

    const payer = String(tx.payer).toLowerCase();
    const payee = String(tx.payee).toLowerCase();

    // 只关注 burn 记录 (payer=account, payee=buint)
    if (payee !== buintLower || payer !== accountLower) continue;
    burnCount++;

    const rawId = tx.id;
    const txIdHex = typeof rawId === "string" ? rawId : rawId != null ? "0x" + BigInt(rawId).toString(16).padStart(64, "0") : "0x";

    const rawOph = tx.originalPaymentHash;
    const ophHex = rawOph != null
      ? (typeof rawOph === "string" ? rawOph : "0x" + BigInt(rawOph).toString(16).padStart(64, "0"))
      : "(null)";

    const txCat = tx.txCategory;
    const txCatHex = txCat != null ? (typeof txCat === "string" ? txCat : "0x" + BigInt(txCat).toString(16).padStart(64, "0")) : "(null)";
    const isRequestAccounting = txCatHex.toLowerCase() === TX_REQUEST_ACCOUNTING.toLowerCase();
    const isSendUSDC = txCatHex.toLowerCase() === TX_SEND_USDC.toLowerCase();
    const isX402Send = txCatHex.toLowerCase() === TX_X402_SEND.toLowerCase();

    console.log("\n--- Burn 记录 #" + burnCount + " (page index " + i + ") ---");
    console.log("  id (txId):", txIdHex);
    console.log("  originalPaymentHash (raw):", rawOph);
    console.log("  originalPaymentHash (type):", typeof rawOph);
    console.log("  originalPaymentHash (hex):", ophHex);
    console.log("  originalPaymentHash === ZeroHash:", rawOph === eth.ZeroHash);
    console.log("  ethers.isHexString(rawOph):", rawOph != null && eth.isHexString(rawOph));
    console.log("  ethers.dataLength(rawOph):", rawOph != null && eth.isHexString(rawOph) ? eth.dataLength(rawOph) : "N/A");
    console.log("  txCategory:", txCatHex);
    console.log("  isRequestAccounting:", isRequestAccounting);
    console.log("  isSendUSDC (AAtoEOA/Container):", isSendUSDC);
    console.log("  isX402Send:", isX402Send);
    console.log("  payer:", tx.payer);
    console.log("  payee:", tx.payee);
    console.log("  finalRequestAmountFiat6:", tx.finalRequestAmountFiat6?.toString());
    console.log("  finalRequestAmountUSDC6:", tx.finalRequestAmountUSDC6?.toString());
    console.log("  timestamp:", tx.timestamp?.toString());

    // 完整 JSON 输出（便于调试）
    const txObj = tx as Record<string, unknown>;
    const safeTx: Record<string, unknown> = {};
    for (const k of Object.keys(txObj)) {
      const v = txObj[k];
      if (typeof v === "bigint") safeTx[k] = v.toString();
      else if (v && typeof v === "object" && !Array.isArray(v)) {
        safeTx[k] = Object.fromEntries(
          Object.entries(v as Record<string, unknown>).map(([kk, vv]) => [kk, typeof vv === "bigint" ? vv.toString() : vv])
        );
      } else safeTx[k] = v;
    }
    try {
      console.log("  完整结构 (JSON):", JSON.stringify(safeTx, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
    } catch (_) {
      console.log("  (JSON 序列化跳过)");
    }
  }

  console.log("\n" + "=".repeat(70));
  console.log("Burn 记录总数:", burnCount);
  console.log("检查完成");
}

main().catch(console.error);
