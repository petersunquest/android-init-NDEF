/**
 * Probe BeamioIndexerDiamond on CoNET mainnet for accountActionIds tail (Merchant OS 同源 RPC).
 *
 * Usage (from repo root):
 *   node scripts/ledgerProbeIndexerAccount.mjs 0xYourEoaOrAa
 *
 * Env:
 *   CONET_RPC — default https://rpc1.conet.network
 *   BEAMIO_INDEXER_DIAMOND — default matches bizSite chainAddresses
 */
import { ethers } from 'ethers';

const RPC = process.env.CONET_RPC || 'https://rpc1.conet.network';
const DIAMOND = process.env.BEAMIO_INDEXER_DIAMOND || '0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe';

const TX_PAGE_TUPLE = `tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists, address topAdmin, address subordinate)`;

const abi = [
  'function getAccountActionCount(address account) view returns (uint256)',
  `function getAccountTransactionsPaged(address account, uint256 offset, uint256 limit) view returns (${TX_PAGE_TUPLE}[] page)`,
];

const raw = process.argv[2];
if (!raw || !ethers.isAddress(raw)) {
  console.error('Usage: node scripts/ledgerProbeIndexerAccount.mjs <0xAddress>');
  process.exit(1);
}

const account = ethers.getAddress(raw);
const provider = new ethers.JsonRpcProvider(RPC);
const c = new ethers.Contract(DIAMOND, abi, provider);

const n = await c.getAccountActionCount(account);
const total = Number(n);
console.log(JSON.stringify({ rpc: RPC, diamond: DIAMOND, account, getAccountActionCount: total }, null, 2));

if (!Number.isFinite(total) || total <= 0) {
  console.log('No account-indexed actions for this address (indexer may not yet record this identity, or address wrong).');
  process.exit(0);
}

/** ActionFacet.getAccountTransactionsPaged: offset 0 = newest (revIndex = total-1-(offset+i)). */
const lim = Math.min(20, total);
const off = 0;
const page = await c.getAccountTransactionsPaged(account, off, lim);
console.log('Latest window (newest-first):', { offset: off, limit: lim, returned: page.length });

for (let i = 0; i < page.length; i++) {
  const tx = page[i];
  const dj = (() => {
    try {
      return JSON.parse(tx.displayJson || '{}');
    } catch {
      return {};
    }
  })();
  console.log(
    JSON.stringify(
      {
        i,
        id: tx.id,
        exists: tx.exists,
        timestamp: Number(tx.timestamp),
        iso: new Date(Number(tx.timestamp) * 1000).toISOString(),
        payer: tx.payer,
        payee: tx.payee,
        txCategory: tx.txCategory,
        topAdmin: tx.topAdmin,
        subordinate: tx.subordinate,
        displayTerminal: dj.terminal,
        displayHandle: dj.handle,
      },
      null,
      2,
    ),
  );
}
