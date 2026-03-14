/**
 * 从 CoNET Indexer 拉取 request_create 原始记账，排查 bServiceUSDC6/bServiceUnits6 为 0 的原因
 *
 * 用法: npx tsx scripts/checkRequestCreateIndexerFees.ts
 * 可选: TX_ID=0x... ACCOUNT=0x... npx tsx scripts/checkRequestCreateIndexerFees.ts
 */
import { ethers } from 'ethers'

const INDEXER = '0x9d481CC9Da04456e98aE2FD6eB6F18e37bf72eb5'
const CONET_RPC = 'https://mainnet-rpc.conet.network'

const INDEXER_ABI = [
	'function getTransactionFullByTxId(bytes32 txId) view returns ((bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, (address asset, uint256 amountE6, uint8 assetType, uint8 source, uint256 tokenId, uint8 itemCurrencyType, uint256 offsetInRequestCurrencyE6)[] route, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta))',
	'function getAccountTransactionsByMonthOffsetPaged(address account, uint256 periodOffset, uint256 pageOffset, uint256 pageLimit, bytes32 txCategoryFilter) view returns (uint256 total, uint256 periodStart, uint256 periodEnd, (bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)[] page)',
] as const

const TX_REQUEST_CREATE = ethers.keccak256(ethers.toUtf8Bytes('request_create:confirmed'))

function serializeFees(fees: unknown): Record<string, string> {
	if (!fees || typeof fees !== 'object') return {}
	const f = fees as Record<string | number, unknown>
	const keys = ['gasChainType', 'gasWei', 'gasUSDC6', 'serviceUSDC6', 'bServiceUSDC6', 'bServiceUnits6', 'feePayer']
	const out: Record<string, string> = {}
	for (let i = 0; i < 7; i++) {
		const v = f[keys[i]] ?? f[i]
		out[keys[i]] = v != null ? String(v) : '(undefined)'
	}
	return out
}

async function main() {
	const TX_ID = process.env.TX_ID || '0xb7d35f1349d6ee3a2f7767f3bcf3eec803bb181f26016b03645b08020889fe12'
	const ACCOUNT = process.env.ACCOUNT || '0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61'

	const provider = new ethers.JsonRpcProvider(CONET_RPC)
	const indexer = new ethers.Contract(INDEXER, INDEXER_ABI, provider)

	console.log('=== CoNET Indexer 原始记账排查 ===\n')
	console.log('Indexer:', INDEXER)
	console.log('RPC:', CONET_RPC)
	console.log('txId:', TX_ID)
	console.log('account:', ACCOUNT)
	console.log('')

	// 1. getTransactionFullByTxId
	console.log('1. getTransactionFullByTxId(txId):')
	try {
		const full = await indexer.getTransactionFullByTxId(TX_ID)
		// ethers v6: 返回 struct，可能为具名对象或数组
		const tx = (full && typeof full === 'object') ? full : null
		const fees = tx?.fees ?? tx?.[12]
		if (tx && (tx.id ?? tx[0])) {
			console.log('   id:', tx.id ?? tx[0])
			console.log('   payer:', tx.payer ?? tx[6])
			console.log('   payee:', tx.payee ?? tx[7])
			console.log('   finalRequestAmountUSDC6:', (tx.finalRequestAmountUSDC6 ?? tx[9])?.toString())
			console.log('   txCategory:', tx.txCategory ?? tx[3])
			console.log('   fees (raw):', JSON.stringify(serializeFees(fees), null, 2))
			console.log('   bServiceUSDC6:', fees?.bServiceUSDC6 ?? fees?.[4], '(index 4)')
			console.log('   bServiceUnits6:', fees?.bServiceUnits6 ?? fees?.[5], '(index 5)')
			if (Number(fees?.bServiceUSDC6 ?? fees?.[4] ?? 0) === 0 && Number(fees?.bServiceUnits6 ?? fees?.[5] ?? 0) === 0) {
				console.log('   ⚠️ 链上 fees 为 0，说明 requestAccounting syncTokenAction 时未正确传入 bServiceUSDC6/bServiceUnits6')
				console.log('   预期：1 USDC request -> 2 B-Units (min), bServiceUSDC6=20000, bServiceUnits6=2000000')
			}
		} else {
			console.log('   ❌ 未找到')
		}
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 2. getAccountTransactionsByMonthOffsetPaged for account
	console.log('\n2. getAccountTransactionsByMonthOffsetPaged(account, 0, 0, 30, 0x00):')
	try {
		const [total, , , page] = await indexer.getAccountTransactionsByMonthOffsetPaged(
			ACCOUNT,
			0,
			0,
			30,
			ethers.ZeroHash
		)
		console.log('   total:', total.toString())
		const targetTx = page?.find((t: { id: string }) => ethers.hexlify(t.id ?? t[0]) === TX_ID)
		if (targetTx) {
			console.log('   ✅ 目标 tx 在列表中')
			console.log('   fees:', JSON.stringify(serializeFees(targetTx.fees), null, 2))
		} else {
			console.log('   前 5 条 id:')
			page?.slice(0, 5).forEach((t: { id: string; fees: unknown }, i: number) => {
				console.log(`     [${i}] id=${ethers.hexlify(t.id ?? t[0])} fees.bServiceUnits6=${t.fees?.bServiceUnits6 ?? t.fees?.[5] ?? '?'}`)
			})
		}
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 3. 也查 payee 0xc4c14f2A7566B7176a98E6D4E2fF9961C5D05d95（tx 中的 payer/payee）
	console.log('\n3. getAccountTransactionsByMonthOffsetPaged(0xc4c14f2A7566B7176a98E6D4E2fF9961C5D05d95, ...):')
	try {
		const [total, , , page] = await indexer.getAccountTransactionsByMonthOffsetPaged(
			'0xc4c14f2A7566B7176a98E6D4E2fF9961C5D05d95',
			0,
			0,
			30,
			ethers.ZeroHash
		)
		const targetTx = page?.find((t: { id: string }) => ethers.hexlify(t.id ?? t[0]) === TX_ID)
		console.log('   total:', total.toString())
		if (targetTx) {
			console.log('   ✅ 目标 tx 在 payee 列表中, fees.bServiceUnits6:', targetTx.fees?.bServiceUnits6 ?? targetTx.fees?.[5])
		}
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}
}

main()
	.then(() => process.exit(0))
	.catch((err) => {
		console.error(err)
		process.exit(1)
	})
