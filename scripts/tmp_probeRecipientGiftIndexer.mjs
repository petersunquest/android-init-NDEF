import { ethers } from 'ethers'

const INDEXER = '0xd764eBA64536cFF1bbE7e7c7Bbc90F35620f72a9'
const TX_ID = '0x0f0b28d558baec61ea5e7920405ddaa8b6405370dab3cc3c2fe87dde406fd5fb'
const EOA = '0x3Ca84050541F4A2f570F717C9D52624161dFaa7f'
const TX_RECORD_TUPLE =
  '(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists, address topAdmin, address subordinate)'
const abi = [
  `function getAccountTransactionsByMonthOffsetPaged(address account, uint256 periodOffset, uint256 pageOffset, uint256 pageLimit, bytes32 txCategoryFilter) view returns (uint256 total, uint256 periodStart, uint256 periodEnd, ${TX_RECORD_TUPLE}[] page)`,
  'function getAccountTransactionsPaged(address account, uint256 offset, uint256 limit) view returns (tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists, address topAdmin, address subordinate)[] page)',
]

const p = new ethers.JsonRpcProvider('https://rpc1.conet.network')
const idx = new ethers.Contract(INDEXER, abi, p)
const filter = ethers.ZeroHash

console.log('=== getAccountTransactionsPaged (flat) ===')
const flat = await idx.getAccountTransactionsPaged(EOA, 0, 20)
for (const t of flat) {
  const id = String(t.id).toLowerCase()
  const dj = t.displayJson
  console.log(id.slice(0, 10) + '...', 'ts', t.timestamp.toString(), 'inbound_payee_match', String(t.payee).toLowerCase() === EOA.toLowerCase(), dj?.slice(0, 80))
  if (id === TX_ID.toLowerCase()) console.log('  ** GIFT TX FOUND in flat page **')
}

console.log('\n=== getAccountTransactionsByMonthOffsetPaged ===')
for (let off = 0; off < 12; off++) {
  const [total, ps, pe, page] = await idx.getAccountTransactionsByMonthOffsetPaged(EOA, off, 0, 30, filter)
  const hit = (page || []).find((t) => String(t.id).toLowerCase() === TX_ID.toLowerCase())
  console.log(
    'monthOffset',
    off,
    'total',
    total.toString(),
    'pageLen',
    page?.length ?? 0,
    'periodStart',
    ps.toString(),
    'hit',
    !!hit
  )
  if (Number(total) === 0) break
}
