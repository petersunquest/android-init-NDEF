/**
 * Migrate old LongDhang BeamioUserCard accounting rows from the legacy CoNET
 * BeamioIndexerDiamond into the current CoNET BeamioIndexerDiamond.
 *
 * Defaults are intentionally dry-run. Set EXECUTE=1 to write on-chain.
 *
 * Dry run:
 *   npx tsx scripts/migrateOldLongDhangCardIndexerToNewConet.ts
 *
 * Execute:
 *   EXECUTE=1 npx tsx scripts/migrateOldLongDhangCardIndexerToNewConet.ts
 *
 * Optional env:
 *   OLD_CONET_RPC=https://rpc1.conet.network
 *   NEW_CONET_RPC=https://publicrpc.conet.network
 *   OLD_INDEXER=0xd764eBA64536cFF1bbE7e7c7Bbc90F35620f72a9
 *   NEW_INDEXER=0x6113fE738489c0aB64B4606Ce333aD29b44ED0C4
 *   CARD=0x30d80cD71Fd1FFD346737b387dA11C7412363EFF
 *   PAGE_SIZE=40
 *   MAX_ROWS=0
 */

import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_CARD = "0x30d80cD71Fd1FFD346737b387dA11C7412363EFF";
const DEFAULT_OLD_INDEXER = "0xd764eBA64536cFF1bbE7e7c7Bbc90F35620f72a9";
const DEFAULT_OLD_RPC = "https://rpc1.conet.network";
const DEFAULT_NEW_RPC = "https://publicrpc.conet.network";
const CONET_CHAIN_ID = 224422n;

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const MASTER_PATH = path.join(homedir(), ".master.json");

const FULL_TX_ABI = [
  "function getTransactionCount() view returns (uint256)",
  "function getAssetActionCount(address asset) view returns (uint256)",
  "function getAssetActionIdsPaged(address asset, uint256 offset, uint256 limit) view returns (uint256[] page)",
  "function getLatestTransactionsPagedFull(uint256 offset, uint256 limit) view returns (uint256 total, (bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, address topAdmin, address subordinate, (address asset, uint256 amountE6, uint8 assetType, uint8 source, uint256 tokenId, uint8 itemCurrencyType, uint256 offsetInRequestCurrencyE6)[] route, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta)[] page)",
  "function getTransactionFull(uint256 actionId) view returns ((bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, address topAdmin, address subordinate, (address asset, uint256 amountE6, uint8 assetType, uint8 source, uint256 tokenId, uint8 itemCurrencyType, uint256 offsetInRequestCurrencyE6)[] route, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta) full)",
  "function getTransactionActionId(bytes32 txId) view returns (uint256 actionId, bool exists)",
  "function syncTokenAction((bytes32 txId, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, (address asset, uint256 amountE6, uint8 assetType, uint8 source, uint256 tokenId, uint8 itemCurrencyType, uint256 offsetInRequestCurrencyE6)[] route, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, address operator, address[] operatorParentChain, address topAdmin, address subordinate) in_) returns (uint256 actionId)",
] as const;

type RouteItem = {
  asset: string;
  amountE6: bigint;
  assetType: bigint | number;
  source: bigint | number;
  tokenId: bigint;
  itemCurrencyType: bigint | number;
  offsetInRequestCurrencyE6: bigint;
};

type FullTx = {
  id: string;
  originalPaymentHash: string;
  chainId: bigint;
  txCategory: string;
  displayJson: string;
  timestamp: bigint;
  payer: string;
  payee: string;
  finalRequestAmountFiat6: bigint;
  finalRequestAmountUSDC6: bigint;
  isAAAccount: boolean;
  topAdmin: string;
  subordinate: string;
  route: RouteItem[];
  fees: {
    gasChainType: bigint | number;
    gasWei: bigint;
    gasUSDC6: bigint;
    serviceUSDC6: bigint;
    bServiceUSDC6: bigint;
    bServiceUnits6: bigint;
    feePayer: string;
  };
  meta: {
    requestAmountFiat6: bigint;
    requestAmountUSDC6: bigint;
    currencyFiat: bigint | number;
    discountAmountFiat6: bigint;
    discountRateBps: bigint | number;
    taxAmountFiat6: bigint;
    taxRateBps: bigint | number;
    afterNotePayer: string;
    afterNotePayee: string;
  };
};

type Candidate = {
  actionId: bigint;
  tx: FullTx;
  reasons: string[];
};

function envAddress(name: string, fallback: string): string {
  const raw = process.env[name]?.trim() || fallback;
  if (!ethers.isAddress(raw)) throw new Error(`${name} is not an address: ${raw}`);
  return ethers.getAddress(raw);
}

function readNewIndexerDefault(): string {
  if (!fs.existsSync(ADDRESSES_PATH)) return "";
  const addrs = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf8"));
  return typeof addrs?.BeamioIndexerDiamond === "string" ? addrs.BeamioIndexerDiamond : "";
}

function loadSigner(provider: ethers.JsonRpcProvider): ethers.Wallet {
  const pkEnv = process.env.PRIVATE_KEY?.trim();
  if (pkEnv) return new ethers.Wallet(pkEnv.startsWith("0x") ? pkEnv : `0x${pkEnv}`, provider);

  if (!fs.existsSync(MASTER_PATH)) {
    throw new Error("No PRIVATE_KEY and ~/.master.json not found");
  }
  const master = JSON.parse(fs.readFileSync(MASTER_PATH, "utf8"));
  const pk = master?.settle_contractAdmin?.[0] ?? master?.beamio_Admins?.[0] ?? master?.admin?.[0];
  if (typeof pk !== "string" || pk.length === 0) {
    throw new Error("No PRIVATE_KEY and no usable admin key in ~/.master.json");
  }
  return new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`, provider);
}

function includesCard(tx: FullTx, card: string): boolean {
  const cardLower = card.toLowerCase();
  return Array.from(tx.route ?? []).some((r) => String(r.asset).toLowerCase() === cardLower);
}

function displayMentionsCard(tx: FullTx, card: string): boolean {
  const text = String(tx.displayJson ?? "").toLowerCase();
  return text.includes(card.toLowerCase());
}

function normalizeTxInput(tx: FullTx) {
  return {
    txId: tx.id,
    originalPaymentHash: tx.originalPaymentHash,
    chainId: BigInt(tx.chainId || CONET_CHAIN_ID),
    txCategory: tx.txCategory,
    displayJson: tx.displayJson ?? "",
    timestamp: Number(tx.timestamp ?? 0n),
    payer: ethers.getAddress(tx.payer),
    payee: ethers.getAddress(tx.payee),
    finalRequestAmountFiat6: BigInt(tx.finalRequestAmountFiat6 ?? 0n),
    finalRequestAmountUSDC6: BigInt(tx.finalRequestAmountUSDC6 ?? 0n),
    isAAAccount: Boolean(tx.isAAAccount),
    route: Array.from(tx.route ?? []).map((r) => ({
      asset: ethers.getAddress(r.asset),
      amountE6: BigInt(r.amountE6 ?? 0n),
      assetType: Number(r.assetType ?? 0),
      source: Number(r.source ?? 0),
      tokenId: BigInt(r.tokenId ?? 0n),
      itemCurrencyType: Number(r.itemCurrencyType ?? 0),
      offsetInRequestCurrencyE6: BigInt(r.offsetInRequestCurrencyE6 ?? 0n),
    })),
    fees: {
      gasChainType: Number(tx.fees?.gasChainType ?? 0),
      gasWei: BigInt(tx.fees?.gasWei ?? 0n),
      gasUSDC6: BigInt(tx.fees?.gasUSDC6 ?? 0n),
      serviceUSDC6: BigInt(tx.fees?.serviceUSDC6 ?? 0n),
      bServiceUSDC6: BigInt(tx.fees?.bServiceUSDC6 ?? 0n),
      bServiceUnits6: BigInt(tx.fees?.bServiceUnits6 ?? 0n),
      feePayer: ethers.getAddress(tx.fees?.feePayer ?? ethers.ZeroAddress),
    },
    meta: {
      requestAmountFiat6: BigInt(tx.meta?.requestAmountFiat6 ?? 0n),
      requestAmountUSDC6: BigInt(tx.meta?.requestAmountUSDC6 ?? 0n),
      currencyFiat: Number(tx.meta?.currencyFiat ?? 0),
      discountAmountFiat6: BigInt(tx.meta?.discountAmountFiat6 ?? 0n),
      discountRateBps: Number(tx.meta?.discountRateBps ?? 0),
      taxAmountFiat6: BigInt(tx.meta?.taxAmountFiat6 ?? 0n),
      taxRateBps: Number(tx.meta?.taxRateBps ?? 0),
      afterNotePayer: tx.meta?.afterNotePayer ?? "",
      afterNotePayee: tx.meta?.afterNotePayee ?? "",
    },
    // Original operator/operatorParentChain are not stored in TransactionFull.
    // Keep them empty so migration does not invent admin token0 aggregate history.
    operator: ethers.ZeroAddress,
    operatorParentChain: [] as string[],
    topAdmin: ethers.getAddress(tx.topAdmin ?? ethers.ZeroAddress),
    subordinate: ethers.getAddress(tx.subordinate ?? ethers.ZeroAddress),
  };
}

function addCandidate(map: Map<string, Candidate>, actionId: bigint, tx: FullTx, reason: string): void {
  const key = tx.id.toLowerCase();
  const existing = map.get(key);
  if (existing) {
    if (!existing.reasons.includes(reason)) existing.reasons.push(reason);
    if (actionId < existing.actionId) existing.actionId = actionId;
    return;
  }
  map.set(key, { actionId, tx, reasons: [reason] });
}

async function main() {
  const execute = process.env.EXECUTE === "1";
  const pageSize = Math.max(1, Number(process.env.PAGE_SIZE || "40"));
  const maxRows = BigInt(process.env.MAX_ROWS || "0");
  const card = envAddress("CARD", DEFAULT_CARD);
  const oldIndexerAddress = envAddress("OLD_INDEXER", DEFAULT_OLD_INDEXER);
  const newIndexerAddress = envAddress("NEW_INDEXER", readNewIndexerDefault() || "0x6113fE738489c0aB64B4606Ce333aD29b44ED0C4");
  const oldRpc = process.env.OLD_CONET_RPC?.trim() || DEFAULT_OLD_RPC;
  const newRpc = process.env.NEW_CONET_RPC?.trim() || process.env.CONET_RPC_URL?.trim() || DEFAULT_NEW_RPC;

  const oldProvider = new ethers.JsonRpcProvider(oldRpc, Number(CONET_CHAIN_ID));
  const newProvider = new ethers.JsonRpcProvider(newRpc, Number(CONET_CHAIN_ID));
  const oldIndexer = new ethers.Contract(oldIndexerAddress, FULL_TX_ABI, oldProvider);
  const newReadIndexer = new ethers.Contract(newIndexerAddress, FULL_TX_ABI, newProvider);
  const signer = execute ? loadSigner(newProvider) : null;
  const newWriteIndexer = signer ? new ethers.Contract(newIndexerAddress, FULL_TX_ABI, signer) : null;

  console.log("=".repeat(88));
  console.log("LongDhang card BeamioIndexerDiamond migration");
  console.log("=".repeat(88));
  console.log("mode:", execute ? "EXECUTE" : "DRY-RUN");
  console.log("card:", card);
  console.log("old RPC:", oldRpc);
  console.log("old indexer:", oldIndexerAddress);
  console.log("new RPC:", newRpc);
  console.log("new indexer:", newIndexerAddress);
  if (signer) console.log("signer:", signer.address);
  console.log("");

  const oldAssetCount = BigInt(await oldIndexer.getAssetActionCount(card));
  const oldTotal = BigInt(await oldIndexer.getTransactionCount());
  console.log("old asset action count:", oldAssetCount.toString());
  console.log("old global tx count:", oldTotal.toString());

  const candidates = new Map<string, Candidate>();
  const directIds = new Set<string>();
  const linkedHashes = new Set<string>();

  for (let offset = 0n; offset < oldAssetCount; offset += BigInt(pageSize)) {
    const ids: bigint[] = await oldIndexer.getAssetActionIdsPaged(card, offset, pageSize);
    for (const rawId of ids) {
      const actionId = BigInt(rawId);
      const tx = await oldIndexer.getTransactionFull(actionId) as FullTx;
      addCandidate(candidates, actionId, tx, "route.asset=card");
      directIds.add(tx.id.toLowerCase());
      if (tx.originalPaymentHash && tx.originalPaymentHash !== ethers.ZeroHash) {
        linkedHashes.add(tx.originalPaymentHash.toLowerCase());
      }
    }
  }

  for (const id of directIds) linkedHashes.add(id);

  const scanLimit = maxRows > 0n && maxRows < oldTotal ? maxRows : oldTotal;
  for (let offset = 0n; offset < scanLimit; offset += BigInt(pageSize)) {
    const limit = Number((offset + BigInt(pageSize) > scanLimit) ? scanLimit - offset : BigInt(pageSize));
    const [total, page] = await oldIndexer.getLatestTransactionsPagedFull(offset, limit);
    const totalBig = BigInt(total);
    for (let i = 0; i < page.length; i++) {
      const tx = page[i] as FullTx;
      const actionId = totalBig - 1n - (offset + BigInt(i));
      const originalLower = String(tx.originalPaymentHash ?? "").toLowerCase();
      if (includesCard(tx, card)) {
        addCandidate(candidates, actionId, tx, "global.route.asset=card");
      } else if (originalLower && originalLower !== ethers.ZeroHash.toLowerCase() && linkedHashes.has(originalLower)) {
        addCandidate(candidates, actionId, tx, "linked.originalPaymentHash");
      } else if (displayMentionsCard(tx, card)) {
        addCandidate(candidates, actionId, tx, "displayJson mentions card");
      }
    }
    console.log(`scanned global page offset=${offset.toString()} limit=${limit} candidates=${candidates.size}`);
  }

  const ordered = Array.from(candidates.values()).sort((a, b) => (a.actionId < b.actionId ? -1 : a.actionId > b.actionId ? 1 : 0));
  console.log("");
  console.log("candidate rows:", ordered.length);

  let alreadyExists = 0;
  let wouldWrite = 0;
  let written = 0;
  let failed = 0;

  for (const item of ordered) {
    const txId = item.tx.id;
    const [, exists] = await newReadIndexer.getTransactionActionId(txId);
    const label = `oldActionId=${item.actionId.toString()} txId=${txId.slice(0, 18)} reasons=${item.reasons.join("+")}`;
    if (exists) {
      alreadyExists += 1;
      console.log(`skip existing ${label}`);
      continue;
    }

    wouldWrite += 1;
    if (!execute) {
      console.log(`would sync ${label}`);
      continue;
    }

    try {
      const input = normalizeTxInput(item.tx);
      const sent = await newWriteIndexer!.syncTokenAction(input);
      console.log(`submitted ${label} hash=${sent.hash}`);
      const receipt = await sent.wait();
      if (!receipt || Number(receipt.status ?? 0) !== 1) {
        throw new Error(`receipt status=${receipt?.status?.toString?.() ?? "unknown"}`);
      }
      written += 1;
      console.log(`synced ${label}`);
    } catch (err) {
      failed += 1;
      console.error(`failed ${label}:`, err instanceof Error ? err.message : err);
    }
  }

  console.log("");
  console.log("=".repeat(88));
  console.log("Summary");
  console.log("=".repeat(88));
  console.log("candidate rows:", ordered.length);
  console.log("already exists:", alreadyExists);
  console.log(execute ? "written:" : "would write:", execute ? written : wouldWrite);
  console.log("failed:", failed);
  console.log("operator/operatorParentChain: not migrated (not stored in TransactionFull); topAdmin/subordinate are preserved.");

  if (!execute) {
    console.log("");
    console.log("Dry-run only. Re-run with EXECUTE=1 to write to the new BeamioIndexerDiamond.");
  }

  if (failed > 0) process.exitCode = 1;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
