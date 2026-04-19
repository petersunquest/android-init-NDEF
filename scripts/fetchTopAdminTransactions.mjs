#!/usr/bin/env node
/**
 * 拉取指定 topAdmin 的记账信息
 * Usage: node scripts/fetchTopAdminTransactions.mjs 0xEb5f3F4E60D80227e1dB91D269b4F1dA35892e7b
 */
import { ethers } from 'ethers'

const TOP_ADMIN = process.argv[2] || '0xEb5f3F4E60D80227e1dB91D269b4F1dA35892e7b'
const ASSET = '0x74f35741ad8bc75d873a8d7d140ae5ffb529ac0f'
const INDEXER = '0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe'
const RPC = 'https://rpc1.conet.network'

const TX_PAGE_TUPLE = 'tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists, address topAdmin, address subordinate)'

const ABI = [
  `function getAssetTransactionsByTopAdminAndCurrentPeriodOffsetAndAccountModePaged(address asset, address topAdmin, uint8 periodType, uint256 periodOffset, uint256 pageOffset, uint256 pageLimit, bytes32 txCategoryFilter, uint8 accountMode, uint256 chainIdFilter) view returns (uint256 total, uint256 periodStart, uint256 periodEnd, ${TX_PAGE_TUPLE}[] page)`,
]

const provider = new ethers.JsonRpcProvider(RPC)
const contract = new ethers.Contract(INDEXER, ABI, provider)

const PERIOD_DAY = 1
const TX_CATEGORY_ZERO = ethers.ZeroHash
const ACCOUNT_MODE_ALL = 0
const CHAIN_ID_FILTER_ALL = ethers.MaxUint256

async function main() {
  console.log('Fetching transactions for topAdmin:', TOP_ADMIN)
  console.log('Asset:', ASSET)
  console.log('---')

  const all = []
  for (const periodOffset of [0, 1, 2]) {
    const [total, periodStart, periodEnd, page] = await contract.getAssetTransactionsByTopAdminAndCurrentPeriodOffsetAndAccountModePaged(
      ASSET, TOP_ADMIN, PERIOD_DAY, periodOffset, 0, 100, TX_CATEGORY_ZERO, ACCOUNT_MODE_ALL, CHAIN_ID_FILTER_ALL
    )
    console.log(`Period offset ${periodOffset}: total=${total}, start=${periodStart}, end=${periodEnd}, page.length=${page.length}`)
    for (const tx of page) {
      all.push({
        id: tx.id,
        txCategory: tx.txCategory,
        displayJson: tx.displayJson,
        timestamp: Number(tx.timestamp),
        payer: tx.payer,
        payee: tx.payee,
        finalRequestAmountUSDC6: tx.finalRequestAmountUSDC6,
        topAdmin: tx.topAdmin,
        subordinate: tx.subordinate,
      })
    }
    if (Number(total) <= 100) break
  }

  all.sort((a, b) => b.timestamp - a.timestamp)

  console.log('\n--- Transactions ---')
  for (const tx of all) {
    const cat = String(tx.txCategory)
    const usdc = Number(tx.finalRequestAmountUSDC6) / 1e6
    const dt = new Date(Number(tx.timestamp) * 1000).toISOString()
    let display = ''
    try {
      const j = JSON.parse(tx.displayJson || '{}')
      display = j.category || j.txCategory || cat.slice(0, 20) || ''
    } catch { display = cat.slice(0, 20) }
    console.log(`${dt} | ${display} | payer=${tx.payer.slice(0, 10)}... | payee=${tx.payee.slice(0, 10)}... | USDC=${usdc} | topAdmin=${tx.topAdmin?.slice(0, 10)}... | subordinate=${tx.subordinate?.slice(0, 10)}...`)
  }
  console.log('\nTotal:', all.length, 'transactions')
}

main().catch(console.error)
