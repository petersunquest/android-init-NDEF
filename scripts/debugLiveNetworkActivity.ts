/**
 * 调试 Live Network Activity：拉取卡 0x4CC2e5A596791cb71E34d7B3177e60f6aB3f73eD 与 EOA 0x513087820Af94A7f4d21bC5B68090f3080022E0e 的 Indexer 记录
 *
 * 用法：npx tsx scripts/debugLiveNetworkActivity.ts
 */
import { ethers } from 'ethers'
import * as fs from 'fs'
import * as path from 'path'
import { fileURLToPath } from 'url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const CARD_ADDRESS = '0x4CC2e5A596791cb71E34d7B3177e60f6aB3f73eD'
const EOA = '0x513087820Af94A7f4d21bC5B68090f3080022E0e'

const TX_RECORD_TUPLE =
	'(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)'

const INDEXER_ABI = [
	`function getAccountTransactionsByMonthOffsetPaged(address account, uint256 periodOffset, uint256 pageOffset, uint256 pageLimit, bytes32 txCategoryFilter) view returns (uint256 total, uint256 periodStart, uint256 periodEnd, ${TX_RECORD_TUPLE}[] page)`,
	`function getAssetActionCount(address asset) view returns (uint256)`,
	`function getAssetTransactionsPaged(address asset, uint256 offset, uint256 limit) view returns (${TX_RECORD_TUPLE}[] page)`,
] as const

const AA_FACTORY = '0xD86403DD1755F7add19540489Ea10cdE876Cc1CE'
const BASE_RPC = 'https://1rpc.io/base'
const CONET_RPC = 'https://mainnet-rpc.conet.network'

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

	const baseProvider = new ethers.JsonRpcProvider(BASE_RPC)
	const conetProvider = new ethers.JsonRpcProvider(CONET_RPC)
	const indexer = new ethers.Contract(diamond, INDEXER_ABI, conetProvider)

	console.log('=== 调试 Live Network Activity ===\n')
	console.log('卡地址:', CARD_ADDRESS)
	console.log('EOA:', EOA)
	console.log('Indexer:', diamond)
	console.log('Base RPC:', BASE_RPC)
	console.log('CoNET RPC:', CONET_RPC)
	console.log('')

	// 1. 获取卡 owner（Base）
	console.log('1. getCardOwner(card) [Base]:')
	let owner: string | null = null
	try {
		const card = new ethers.Contract(CARD_ADDRESS, ['function owner() view returns (address)'], baseProvider)
		owner = ethers.getAddress(await card.owner())
		console.log('   ✅ owner:', owner)
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 2. 获取 owner 的 AA（Base）
	let aa: string | null = null
	if (owner) {
		console.log('\n2. getAAAccount(owner) [Base primaryAccountOf]:')
		try {
			const aaFactory = new ethers.Contract(
				AA_FACTORY,
				['function primaryAccountOf(address eoa) view returns (address)'],
				baseProvider
			)
			const primary = await aaFactory.primaryAccountOf(owner)
			if (primary !== ethers.ZeroAddress) {
				aa = ethers.getAddress(primary)
				console.log('   ✅ AA:', aa)
			} else {
				console.log('   (无 AA)')
			}
		} catch (e) {
			console.log('   ❌ 失败:', (e as Error).message)
		}
	}

	// 3. EOA 的 account 交易（本月）
	console.log('\n3. getAccountTransactionsByMonthOffsetPaged(EOA, 0, 0, 50, 0x00) [CoNET]:')
	try {
		const [total, periodStart, periodEnd, page] = await indexer.getAccountTransactionsByMonthOffsetPaged(
			EOA,
			0,
			0,
			50,
			ethers.ZeroHash
		)
		console.log('   total:', total.toString())
		console.log('   periodStart:', periodStart.toString(), '(' + new Date(Number(periodStart) * 1000).toISOString() + ')')
		console.log('   periodEnd:', periodEnd.toString(), '(' + new Date(Number(periodEnd) * 1000).toISOString() + ')')
		console.log('   page length:', page?.length ?? 0)
		if (page && page.length > 0) {
			page.slice(0, 3).forEach((tx: { id: string; payer: string; payee: string; timestamp: bigint; finalRequestAmountUSDC6: bigint }, i: number) => {
				console.log(`   [${i}] id=${ethers.hexlify(tx.id).slice(0, 18)}... payer=${tx.payer} payee=${tx.payee} ${ethers.formatUnits(tx.finalRequestAmountUSDC6 ?? 0n, 6)} USDC`)
			})
		}
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 4. owner 的 account 交易（本月）
	if (owner) {
		console.log('\n4. getAccountTransactionsByMonthOffsetPaged(owner, 0, 0, 50, 0x00) [CoNET]:')
		try {
			const [total, , , page] = await indexer.getAccountTransactionsByMonthOffsetPaged(
				owner,
				0,
				0,
				50,
				ethers.ZeroHash
			)
			console.log('   total:', total.toString())
			console.log('   page length:', page?.length ?? 0)
			if (page && page.length > 0) {
				page.slice(0, 3).forEach((tx: { id: string; payer: string; payee: string }, i: number) => {
					console.log(`   [${i}] id=${ethers.hexlify(tx.id).slice(0, 18)}... payer=${tx.payer} payee=${tx.payee}`)
				})
			}
		} catch (e) {
			console.log('   ❌ 失败:', (e as Error).message)
		}
	}

	// 5. AA 的 account 交易（本月）
	if (aa) {
		console.log('\n5. getAccountTransactionsByMonthOffsetPaged(AA, 0, 0, 50, 0x00) [CoNET]:')
		try {
			const [total, , , page] = await indexer.getAccountTransactionsByMonthOffsetPaged(
				aa,
				0,
				0,
				50,
				ethers.ZeroHash
			)
			console.log('   total:', total.toString())
			console.log('   page length:', page?.length ?? 0)
			if (page && page.length > 0) {
				page.slice(0, 3).forEach((tx: { id: string; payer: string; payee: string }, i: number) => {
					console.log(`   [${i}] id=${ethers.hexlify(tx.id).slice(0, 18)}... payer=${tx.payer} payee=${tx.payee}`)
				})
			}
		} catch (e) {
			console.log('   ❌ 失败:', (e as Error).message)
		}
	}

	// 6. getAssetActionCount(card) - 卡是否被索引
	console.log('\n6. getAssetActionCount(card) [CoNET]:')
	try {
		const count = await indexer.getAssetActionCount(CARD_ADDRESS)
		console.log('   assetActionIds length:', count.toString())
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 7. getAssetTransactionsPaged(card, 0, 50) - 按 asset 查
	console.log('\n7. getAssetTransactionsPaged(card, 0, 50) [CoNET]:')
	try {
		const page = await indexer.getAssetTransactionsPaged(CARD_ADDRESS, 0, 50)
		const arr = Array.isArray(page) ? page : (page as { page?: unknown[] }).page ?? []
		console.log('   page length:', arr.length)
		if (arr.length > 0) {
			arr.slice(0, 3).forEach((tx: { id: string; payer: string; payee: string; timestamp: bigint }, i: number) => {
				console.log(`   [${i}] id=${ethers.hexlify(tx.id).slice(0, 18)}... payer=${tx.payer} payee=${tx.payee} ts=${tx.timestamp}`)
			})
		}
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 8. 上月 EOA（periodOffset=1）
	console.log('\n8. getAccountTransactionsByMonthOffsetPaged(EOA, 1, 0, 50, 0x00) [上月]:')
	try {
		const [total, periodStart, periodEnd, page] = await indexer.getAccountTransactionsByMonthOffsetPaged(
			EOA,
			1,
			0,
			50,
			ethers.ZeroHash
		)
		console.log('   total:', total.toString())
		console.log('   period:', new Date(Number(periodStart) * 1000).toISOString(), '~', new Date(Number(periodEnd) * 1000).toISOString())
		console.log('   page length:', page?.length ?? 0)
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 9. 模拟浏览器 Live Network Activity 的完整流程：并行调用 EOA + owner + AA + asset
	console.log('\n9. [重现] 模拟浏览器：Promise.all(EOA, owner, AA) + getAssetTransactionsPaged 并行:')
	const accounts = owner && aa ? [EOA, owner, aa] : owner ? [EOA, owner] : [EOA]
	try {
		const accountPromises = accounts.map((account) =>
			indexer.getAccountTransactionsByMonthOffsetPaged(account, 0, 0, 50, ethers.ZeroHash)
		)
		const assetPromise = indexer.getAssetTransactionsPaged(CARD_ADDRESS, 0, 50)
		const [accountResults, assetResult] = await Promise.all([
			Promise.all(accountPromises),
			assetPromise,
		])
		console.log('   ✅ 成功')
		console.log('   accountResults:', accountResults.length, '个账户')
		accountResults.forEach((r: unknown, i: number) => {
			const p = (r as { page?: unknown[] }).page ?? (r as unknown[])[3]
			console.log(`      [${i}] page length:`, Array.isArray(p) ? p.length : 0)
		})
		const arr = Array.isArray(assetResult) ? assetResult : (assetResult as { page?: unknown[] })?.page ?? []
		console.log('   assetResult length:', arr.length)
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
		console.log('   完整错误:', e)
	}

	// 10. 压力测试：连续 5 轮并行请求，尝试触发 "out of result range"
	console.log('\n10. [重现] 压力测试：连续 5 轮并行请求:')
	for (let round = 0; round < 5; round++) {
		try {
			const accountPromises = accounts.map((account) =>
				indexer.getAccountTransactionsByMonthOffsetPaged(account, 0, 0, 50, ethers.ZeroHash)
			)
			const assetPromise = indexer.getAssetTransactionsPaged(CARD_ADDRESS, 0, 50)
			await Promise.all([...accountPromises, assetPromise])
			process.stdout.write(`   轮 ${round + 1} ✅ `)
		} catch (e) {
			console.log(`\n   轮 ${round + 1} ❌`, (e as Error).message)
			break
		}
	}
	console.log('')

	// 11. 原始 eth_call 调试：直接调用 RPC，查看返回
	console.log('\n11. [重现] 原始 eth_call 调试 getAccountTransactionsByMonthOffsetPaged:')
	try {
		const iface = new ethers.Interface(INDEXER_ABI)
		const data = iface.encodeFunctionData('getAccountTransactionsByMonthOffsetPaged', [
			EOA,
			0n,
			0n,
			50n,
			ethers.ZeroHash,
		])
		const result = await conetProvider.call({
			to: diamond,
			data,
		})
		console.log('   result 长度:', result?.length ?? 0)
		if (result && result.length > 200) {
			console.log('   result 前 200 字符:', result.slice(0, 200) + '...')
		}
		const decoded = iface.decodeFunctionResult('getAccountTransactionsByMonthOffsetPaged', result)
		console.log('   decoded total:', decoded[0]?.toString())
		console.log('   decoded page length:', decoded[3]?.length ?? 0)
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	// 12. 使用 fetch 模拟浏览器 eth_call（与 Node ethers 对比）
	console.log('\n12. [重现] fetch 模拟浏览器 eth_call:')
	try {
		const iface = new ethers.Interface(INDEXER_ABI)
		const data = iface.encodeFunctionData('getAccountTransactionsByMonthOffsetPaged', [
			EOA,
			0n,
			0n,
			50n,
			ethers.ZeroHash,
		])
		const body = JSON.stringify({
			jsonrpc: '2.0',
			id: 1,
			method: 'eth_call',
			params: [{ to: diamond, data }, 'latest'],
		})
		const res = await fetch(CONET_RPC, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body,
		})
		const json = await res.json()
		if (json.error) {
			console.log('   ❌ RPC error:', json.error.code, json.error.message)
		} else if (json.result) {
			console.log('   ✅ result 长度:', json.result.length)
			const decoded = iface.decodeFunctionResult('getAccountTransactionsByMonthOffsetPaged', json.result)
			console.log('   decoded page length:', decoded[3]?.length ?? 0)
		} else {
			console.log('   unexpected:', json)
		}
	} catch (e) {
		console.log('   ❌ 失败:', (e as Error).message)
	}

	console.log('\n=== 调试完成 ===')
	console.log('\n结论：Node 环境下无法复现 "out of result range"。')
	console.log('若浏览器仍报错，请打开 DevTools → Network，找到失败的 eth_call 请求，查看 Response 中的 error 详情。')
}

main()
	.then(() => process.exit(0))
	.catch((err) => {
		console.error(err)
		process.exit(1)
	})
