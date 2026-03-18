#!/usr/bin/env node
/**
 * 诊断 Alliance Live Network Activity 数据拉取
 * 模拟 activeHistoryPannelNew 的 3 种查询：asset、topAdmin、subordinate
 * Usage: node scripts/fetchAllianceNetworkActivity.mjs
 */
import { ethers } from 'ethers'

const ASSET = '0x74f35741ad8bc75d873a8d7d140ae5ffb529ac0f' // CashTrees Card
const TOP_ADMIN = '0x8Eb31413EC7Ce13367a39eae203e6659e8F6f32D'
const SUBORDINATE = '0x9817536864A74D2484e18213Cc7a8bAE30c04b66'
const INDEXER = '0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe'
const RPC = 'https://mainnet-rpc.conet.network'

const TX_TUPLE = 'tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)'
const TX_TUPLE_ADMIN = TX_TUPLE.replace('bool exists)', 'bool exists, address topAdmin, address subordinate)')

const ABI = [
  `function getAssetTransactionsPaged(address asset, uint256 offset, uint256 limit) view returns (${TX_TUPLE}[] page)`,
  `function getAssetTransactionsByTopAdminAndCurrentPeriodOffsetAndAccountModePaged(address asset, address topAdmin, uint8 periodType, uint256 periodOffset, uint256 pageOffset, uint256 pageLimit, bytes32 txCategoryFilter, uint8 accountMode, uint256 chainIdFilter) view returns (uint256 total, uint256 periodStart, uint256 periodEnd, ${TX_TUPLE_ADMIN}[] page)`,
  `function getAssetTransactionsBySubordinateAndCurrentPeriodOffsetAndAccountModePaged(address asset, address subordinate, uint8 periodType, uint256 periodOffset, uint256 pageOffset, uint256 pageLimit, bytes32 txCategoryFilter, uint8 accountMode, uint256 chainIdFilter) view returns (uint256 total, uint256 periodStart, uint256 periodEnd, ${TX_TUPLE_ADMIN}[] page)`,
]

const PERIOD_DAY = 1
const TX_CATEGORY_ZERO = ethers.ZeroHash
const ACCOUNT_MODE_ALL = 0
const CHAIN_ID_FILTER_ALL = ethers.MaxUint256

function summarize(tx) {
  const id = typeof tx.id === 'string' ? tx.id : ethers.hexlify(tx.id)
  const cat = String(tx.txCategory || '')
  const disp = (tx.displayJson || '').slice(0, 60)
  const ts = Number(tx.timestamp || 0)
  const dt = ts > 0 ? new Date(ts < 1e10 ? ts * 1000 : ts).toISOString() : '?'
  const usdc = Number(tx.finalRequestAmountUSDC6 || 0) / 1e6
  return { id: id.slice(0, 18) + '...', dt, cat: cat.slice(0, 20), usdc, disp }
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC)
  const contract = new ethers.Contract(INDEXER, ABI, provider)

  console.log('=== Alliance Live Network Activity 数据拉取诊断 ===\n')
  console.log('Asset (CashTrees Card):', ASSET)
  console.log('TopAdmin:', TOP_ADMIN)
  console.log('Subordinate:', SUBORDINATE)
  console.log('Indexer:', INDEXER)
  console.log('RPC:', RPC)
  console.log('')

  try {
    // 1. getAssetTransactionsPaged
    console.log('1. getAssetTransactionsPaged(asset, 0, 50)')
    const assetPage = await contract.getAssetTransactionsPaged(ASSET, 0, 50)
    const assetList = Array.isArray(assetPage) ? (assetPage.length === 1 && Array.isArray(assetPage[0]) ? assetPage[0] : assetPage) : (assetPage?.page ?? [])
    console.log('   count:', assetList.length)
    for (const tx of assetList) {
      console.log('   ', summarize(tx))
    }
    console.log('')

    // 2. getAssetTransactionsByTopAdmin (periodOffset=0,1,2)
    console.log('2. getAssetTransactionsByTopAdmin(asset, topAdmin, PERIOD_DAY, 0..2)')
    for (const periodOffset of [0, 1, 2]) {
      const [total, periodStart, periodEnd, page] = await contract.getAssetTransactionsByTopAdminAndCurrentPeriodOffsetAndAccountModePaged(
        ASSET, TOP_ADMIN, PERIOD_DAY, periodOffset, 0, 50, TX_CATEGORY_ZERO, ACCOUNT_MODE_ALL, CHAIN_ID_FILTER_ALL
      )
      console.log(`   periodOffset=${periodOffset}: total=${total}, page.length=${page.length}`)
      for (const tx of page) {
        console.log('   ', summarize(tx), 'topAdmin=' + (tx.topAdmin || '').slice(0, 12) + '...')
      }
    }
    console.log('')

    // 3. getAssetTransactionsBySubordinate
    console.log('3. getAssetTransactionsBySubordinate(asset, subordinate, PERIOD_DAY, 0..2)')
    for (const periodOffset of [0, 1, 2]) {
      const [total, periodStart, periodEnd, page] = await contract.getAssetTransactionsBySubordinateAndCurrentPeriodOffsetAndAccountModePaged(
        ASSET, SUBORDINATE, PERIOD_DAY, periodOffset, 0, 50, TX_CATEGORY_ZERO, ACCOUNT_MODE_ALL, CHAIN_ID_FILTER_ALL
      )
      console.log(`   periodOffset=${periodOffset}: total=${total}, page.length=${page.length}`)
      for (const tx of page) {
        console.log('   ', summarize(tx))
      }
    }
  } catch (e) {
    console.error('Error:', e.message)
    if (e.code) console.error('Code:', e.code)
  }
}

main().catch(console.error)
