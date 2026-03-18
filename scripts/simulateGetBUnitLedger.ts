/**
 * 模拟 getBUnitLedger 的转换逻辑，检查输出是否包含 originalPaymentHash
 * 用法: npx hardhat run scripts/simulateGetBUnitLedger.ts --network conet
 */

import { network as networkModule } from "hardhat";
import { ethers } from "ethers";

const INDEXER = "0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe";
const BUINT = "0x4A3E59519eE72B9Dcf376f0617fF0a0a5a1ef879";

const ABI = [
  "function getAccountTransactionsPaged(address account, uint256 offset, uint256 limit) view returns (tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)[] page)",
];

const TX_BUINT_CLAIM = ethers.keccak256(ethers.toUtf8Bytes("buintClaim"));
const TX_BUINT_USDC = ethers.keccak256(ethers.toUtf8Bytes("buintUSDC"));
const TX_REQUEST_ACCOUNTING = ethers.keccak256(ethers.toUtf8Bytes("requestAccounting"));

async function main() {
  const account = process.env.CHECK_ACCOUNT || "0x513087820Af94A7f4d21bC5B68090f3080022E0e";

  const { ethers: eth } = await networkModule.connect();
  const indexer = new eth.Contract(INDEXER, ABI, eth.provider);

  const page = await indexer.getAccountTransactionsPaged(account, 0, 100);
  const accountLower = account.toLowerCase();
  const buintLower = BUINT.toLowerCase();
  const decimals = 6;

  const formatTime = (ts: number) => {
    const d = new Date(ts * 1000);
    const now = Date.now();
    const diff = now - ts * 1000;
    if (diff < 60 * 60 * 1000) return `${Math.floor(diff / 60000)}m ago`;
    if (diff < 24 * 60 * 60 * 1000) return `${Math.floor(diff / 3600000)}h ago`;
    if (diff < 48 * 60 * 60 * 1000) return "Yesterday";
    return d.toLocaleDateString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
  };

  const entries: Array<Record<string, unknown>> = [];

  for (const tx of page) {
    if (!tx?.exists) continue;
    const txCategory = String(tx.txCategory);
    const payer = String(tx.payer).toLowerCase();
    const payee = String(tx.payee).toLowerCase();
    const amountFiat6 = Number(tx.finalRequestAmountFiat6 ?? 0);
    const amountUSDC6 = Number(tx.finalRequestAmountUSDC6 ?? 0);
    const amountBUnits = Math.round(amountFiat6 / 10 ** decimals);
    const ts = Number(tx.timestamp ?? 0);
    const timeStr = ts ? formatTime(ts) : "—";
    const rawId = tx.id;
    const txIdHex = typeof rawId === "string" ? rawId : rawId != null ? "0x" + BigInt(rawId).toString(16).padStart(64, "0") : "0x";
    const txHashShort = txIdHex.length > 10 ? `${txIdHex.slice(0, 6)}...${txIdHex.slice(-4)}` : txIdHex;
    const baseEntry = { time: timeStr, timestamp: ts, txHash: txHashShort, network: "CoNET L1", status: "Completed" };

    if (txCategory === TX_BUINT_CLAIM && payee === accountLower) {
      entries.push({ ...baseEntry, id: txIdHex, title: "BUnit Claim", subtitle: "Free claim", amount: amountBUnits, type: "reward", linkedUsdc: "N/A" });
    } else if (txCategory === TX_BUINT_USDC && payee === accountLower) {
      const usdcAmount = amountUSDC6 > 0 ? amountUSDC6 / 10 ** decimals : amountBUnits / 100;
      const usdcStr = usdcAmount > 0 ? `-${usdcAmount.toFixed(2)} USDC` : "N/A";
      const rawOph = (tx as { originalPaymentHash?: string }).originalPaymentHash;
      const baseTxHash = rawOph && rawOph !== eth.ZeroHash && eth.isHexString(rawOph) && eth.dataLength(rawOph) === 32 ? rawOph : undefined;
      entries.push({ ...baseEntry, id: txIdHex, title: "Fuel Yield (1:100)", subtitle: "System Top-up", amount: amountBUnits, type: "refuel", linkedUsdc: usdcStr, baseTxHash });
    } else if (payee === buintLower && payer === accountLower) {
      // 与 beamioServer 完全一致的转换逻辑
      const rawOphVal = (tx as { originalPaymentHash?: string | bigint }).originalPaymentHash;
      const rawOph = rawOphVal != null
        ? (typeof rawOphVal === "string" ? rawOphVal : "0x" + BigInt(rawOphVal).toString(16).padStart(64, "0"))
        : undefined;
      const txCatNorm = (typeof txCategory === "string" ? txCategory : txCategory != null ? "0x" + BigInt(txCategory).toString(16).padStart(64, "0") : "").toLowerCase();
      const isRequestAccounting = txCatNorm === TX_REQUEST_ACCOUNTING.toLowerCase();
      const ophHex = rawOph && rawOph !== eth.ZeroHash && eth.isHexString(rawOph) && eth.dataLength(rawOph) === 32 ? (rawOph.startsWith("0x") ? rawOph : "0x" + rawOph) : "";
      const baseTxHash = !isRequestAccounting && ophHex && eth.dataLength(ophHex) === 32 ? ophHex : undefined;
      const originalPaymentHash = isRequestAccounting && ophHex && eth.dataLength(ophHex) === 32 ? ophHex : undefined;
      const title = isRequestAccounting ? "Service Fee (0.8%)" : "B-Unit Burn";
      const subtitle = isRequestAccounting
        ? `Payment Request ${ophHex ? ophHex.slice(-3) : "—"}`
        : (amountUSDC6 > 0 ? `Paid ${(amountUSDC6 / 10 ** decimals).toFixed(2)} USDC` : "Gas / Fee");

      const entry = {
        ...baseEntry,
        id: txIdHex,
        title,
        subtitle,
        amount: -amountBUnits,
        type: amountUSDC6 > 0 ? "fee" : "gas",
        linkedUsdc: amountUSDC6 > 0 ? `${(amountUSDC6 / 10 ** decimals).toFixed(2)} USDC` : "N/A",
        baseTxHash,
        originalPaymentHash,
      };
      entries.push(entry);

      console.log("\n--- Burn 转换调试 ---");
      console.log("  rawOphVal:", rawOphVal, "type:", typeof rawOphVal);
      console.log("  rawOph:", rawOph);
      console.log("  ophHex:", ophHex, "length:", ophHex?.length);
      console.log("  eth.dataLength(ophHex):", ophHex ? eth.dataLength(ophHex) : "N/A");
      console.log("  isRequestAccounting:", isRequestAccounting);
      console.log("  originalPaymentHash (output):", originalPaymentHash);
      console.log("  entry.originalPaymentHash:", entry.originalPaymentHash);
    }
  }

  entries.sort((a, b) => (b.timestamp as number) - (a.timestamp as number));

  const body = JSON.stringify(entries);
  console.log("\n=== 模拟 API 返回的 JSON (前 2000 字符) ===");
  console.log(body.slice(0, 2000));

  // 检查 requestAccounting 类型的 entry 是否包含 originalPaymentHash
  const reqAccEntries = entries.filter((e) => e.title === "Service Fee (0.8%)");
  console.log("\n=== Service Fee (0.8%) 记录数:", reqAccEntries.length);
  for (const e of reqAccEntries) {
    console.log("  id:", (e.id as string)?.slice(0, 18) + "...", "originalPaymentHash:", e.originalPaymentHash ? "✅ 有" : "❌ 无");
  }
}

main().catch(console.error);
