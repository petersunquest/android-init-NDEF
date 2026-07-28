/**
 * 诊断：受益人(payee) 0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61 能否从 CoNET Indexer 获取到该笔转账的 raw 数据
 *
 * 用法：npx tsx scripts/checkPayeeIndexerTx.ts
 */
import { ethers } from 'ethers'
import * as fs from 'fs'
import * as path from 'path'
import { fileURLToPath } from 'url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const INDEXER_ABI = [
	'function getAccountTransactionsByMonthOffsetPaged(address account, uint256 periodOffset, uint256 pageOffset, uint256 pageLimit, bytes32 txCategoryFilter) view returns (uint256 total, uint256 periodStart, uint256 periodEnd, (bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)[] page)',
	'function getTransactionFullByTxId(bytes32 txId) view returns ((bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, (address asset, uint256 amountE6, uint8 assetType, uint8 source, uint256 tokenId, uint8 itemCurrencyType, uint256 offsetInRequestCurrencyE6)[] route, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta))',
	'function getAccountActionCount(address account) view returns (uint256)',
] as const

const PAYEE = '0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61'
const PAYER = '0x513087820Af94A7f4d21bC5B68090f3080022E0e'
const TX_ID = '0xd4a07b76d8b7968a4fd8ca7fc422d28046bfcee1c38974faa16798e8ab262537'

function serializeTx(tx: unknown): Record<string, unknown> {
	if (!tx || typeof tx !== 'object') return {}
	const out: Record<string, unknown> = {}
	for (const [k, v] of Object.entries(tx)) {
		if (typeof k === 'string' && k !== 'length' && !k.match(/^\d+$/)) {
			if (typeof v === 'bigint') out[k] = v.toString()
			else if (Array.isArray(v)) out[k] = v.map((x) => (typeof x === 'bigint' ? x.toString() : x))
			else if (v && typeof v === 'object' && !Array.isArray(v)) out[k] = serializeTx(v)
			else out[k] = v
		}
	}
	return out
}

async function main() {
	const deployPath = path.join(__dirname, '..', 'deployments', 'conet-IndexerDiamond.json')
	const deploy = JSON.parse(fs.readFileSync(deployPath, 'utf8'))
	const diamond = deploy.diamond
	if (!diamond) throw new Error('缺少 diamond 地址')

	const provider = new ethers.JsonRpcProvider('https://rpc1.conet.network')
	const indexer = new ethers.Contract(diamond, INDEXER_ABI, provider)

	console.log('=== 诊断：受益人 Recent Activity 数据 ===\n')
	console.log('Indexer:', diamond)
	console.log('CoNET RPC: https://rpc1.conet.network')
	console.log('目标 txId:', TX_ID)
	console.log('Payer:', PAYER)
	console.log('Payee (受益人):', PAYEE)
	console.log('')

	// 1. 检查 payee 的 accountActionCount
	try {
		const payeeCount = await indexer.getAccountActionCount(PAYEE)
		console.log('1. getAccountActionCount(payee):', payeeCount.toString())
	} catch (e) {
		console.log('1. getAccountActionCount(payee) 失败:', (e as Error).message)
	}

	// 2. 检查 payer 的 accountActionCount（对比）
	try {
		const payerCount = await indexer.getAccountActionCount(PAYER)
		console.log('2. getAccountActionCount(payer):', payerCount.toString())
	} catch (e) {
		console.log('2. getAccountActionCount(payer) 失败:', (e as Error).message)
	}

	// 3. 按 txId 直接查询完整 Transaction（验证该 tx 是否已入 Indexer）
	console.log('\n3. getTransactionFullByTxId(txId):')
	try {
		const full = await indexer.getTransactionFullByTxId(TX_ID)
		if (full && full[0]) {
			const tx = full[0]
			console.log('   ✅ 找到！payer:', tx.payer, 'payee:', tx.payee)
			console.log('   Raw (serialized):')
			console.log(JSON.stringify(serializeTx(tx), null, 2))
		} else {
			console.log('   ❌ 返回空或不存在')
		}
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 4. 查询 payee 的本月交易列表
	console.log('\n4. getAccountTransactionsByMonthOffsetPaged(payee, 0, 0, 20, 0x00):')
	try {
		const [total, periodStart, periodEnd, page] = await indexer.getAccountTransactionsByMonthOffsetPaged(
			PAYEE,
			0,
			0,
			20,
			ethers.ZeroHash
		)
		console.log('   total:', total.toString())
		console.log('   periodStart:', periodStart.toString(), '(' + new Date(Number(periodStart) * 1000).toISOString() + ')')
		console.log('   periodEnd:', periodEnd.toString(), '(' + new Date(Number(periodEnd) * 1000).toISOString() + ')')
		console.log('   page length:', page?.length ?? 0)

		const targetTx = page?.find((tx: { id: string }) => ethers.hexlify(tx.id) === TX_ID)
		if (targetTx) {
			console.log('   ✅ 目标 tx 在 payee 的本月列表（前20条）中！')
			console.log('   Raw:', JSON.stringify(serializeTx(targetTx), null, 2))
		} else {
			console.log('   ❌ 目标 tx 不在 payee 的本月列表前20条中')
			// 可能在第2页（offset 20）
			const [, , , page2] = await indexer.getAccountTransactionsByMonthOffsetPaged(PAYEE, 0, 20, 20, ethers.ZeroHash)
			const targetTx2 = page2?.find((tx: { id: string }) => ethers.hexlify(tx.id) === TX_ID)
			if (targetTx2) {
				console.log('   ✅ 目标 tx 在第2页（offset 20）中！说明 pageLimit=20 导致前20条未包含此 tx')
			}
			if (page && page.length > 0) {
				console.log('   前几条 id:')
				page.slice(0, 5).forEach((tx: { id: string; payee: string; payer: string }, i: number) => {
					console.log(`     [${i}] id=${ethers.hexlify(tx.id)} payer=${tx.payer} payee=${tx.payee}`)
				})
			}
		}
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 5. 查询 payer 的本月交易列表（对比）
	console.log('\n5. getAccountTransactionsByMonthOffsetPaged(payer, 0, 0, 20, 0x00):')
	try {
		const [total, , , page] = await indexer.getAccountTransactionsByMonthOffsetPaged(
			PAYER,
			0,
			0,
			20,
			ethers.ZeroHash
		)
		console.log('   total:', total.toString())
		const targetTx = page?.find((tx: { id: string }) => ethers.hexlify(tx.id) === TX_ID)
		console.log('   目标 tx 在 payer 列表中:', targetTx ? '✅ 是' : '❌ 否')
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 6. 检查 timestamp 是否落在本月周期内
	const ts = 1771997635
	const now = Math.floor(Date.now() / 1000)
	console.log('\n6. 时间检查:')
	console.log('   tx timestamp:', ts, '(' + new Date(ts * 1000).toISOString() + ')')
	console.log('   now:', now, '(' + new Date(now * 1000).toISOString() + ')')
}

main()
	.then(() => process.exit(0))
	.catch((err) => {
		console.error(err)
		process.exit(1)
	})
