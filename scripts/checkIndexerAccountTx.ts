/**
 * 检查 Indexer 中指定地址的本月交易
 * npx hardhat run scripts/checkIndexerAccountTx.ts --network conet
 */
import { ethers } from 'ethers'
import * as fs from 'fs'
import * as path from 'path'
import { fileURLToPath } from 'url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const INDEXER_ABI = [
	'function getAccountTransactionsByMonthOffsetPaged(address account, uint256 periodOffset, uint256 pageOffset, uint256 pageLimit, bytes32 txCategoryFilter) view returns (uint256 total, uint256 periodStart, uint256 periodEnd, (bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, (uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, (uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists)[] page)',
] as const

async function main() {
	const account = process.env.ACCOUNT || '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
	const deployPath = path.join(__dirname, '..', 'deployments', 'conet-IndexerDiamond.json')
	const deploy = JSON.parse(fs.readFileSync(deployPath, 'utf8'))
	const diamond = deploy.diamond
	if (!diamond) throw new Error('缺少 diamond 地址')

	const provider = new ethers.JsonRpcProvider('https://rpc1.conet.network')
	const indexer = new ethers.Contract(diamond, INDEXER_ABI, provider)

	console.log('Indexer:', diamond)
	console.log('Account:', account)
	console.log('Querying getAccountTransactionsByMonthOffsetPaged(account, 0, 0, 20, 0x00)...\n')

	try {
		// 本月 + 上月
		for (const periodOffset of [0, 1]) {
			const [total, periodStart, periodEnd, page] = await indexer.getAccountTransactionsByMonthOffsetPaged(
				account,
				periodOffset,
				0,
				20,
				ethers.ZeroHash
			)
			console.log(`--- periodOffset=${periodOffset} (${periodOffset === 0 ? '本月' : '上月'}) ---`)

			console.log('total:', total.toString())
			console.log('periodStart:', periodStart.toString(), '(' + new Date(Number(periodStart) * 1000).toISOString() + ')')
			console.log('periodEnd:', periodEnd.toString(), '(' + new Date(Number(periodEnd) * 1000).toISOString() + ')')
			console.log('page length:', page?.length ?? 0)

			if (page && page.length > 0) {
				page.forEach((tx: { id: string; displayJson: string; timestamp: bigint; payer: string; payee: string; finalRequestAmountUSDC6: bigint; exists: boolean }, i: number) => {
					if (!tx?.exists) return
					console.log(`  [${i}] id: ${tx.id} | ${ethers.formatUnits(tx.finalRequestAmountUSDC6 ?? 0n, 6)} USDC | ${new Date(Number(tx.timestamp) * 1000).toISOString()}`)
				})
			} else {
				console.log('  (empty)')
			}
			console.log('')
		}
	} catch (e: unknown) {
		console.error('Error:', e instanceof Error ? e.message : e)
		throw e
	}
}

main()
	.then(() => process.exit(0))
	.catch((err) => {
		console.error(err)
		process.exit(1)
	})
