/**
 * 检查 Base 和 CoNET 链上 BeamioOracle 的数据完整性。
 * 验证 0-9 货币（CAD/USD/JPY/CNY/USDC/HKD/EUR/SGD/TWD/ETH）的汇率是否已配置。
 *
 * 运行：npx tsx scripts/checkBeamioOracleIntegrity.ts
 */
import { ethers } from 'ethers'

const ORACLE_ABI = ['function getRate(uint8 c) view returns (uint256)']

const CURRENCIES: Record<number, string> = {
	0: 'CAD',
	1: 'USD',
	2: 'JPY',
	3: 'CNY',
	4: 'USDC',
	5: 'HKD',
	6: 'EUR',
	7: 'SGD',
	8: 'TWD',
	9: 'ETH',
}

const BASE_RPC = process.env.BASE_RPC_URL || 'https://base-rpc.conet.network'
const CONET_RPC = process.env.CONET_RPC_URL || 'https://mainnet-rpc.conet.network'

const ORACLE_BASE = process.env.BASE_BEAMIO_ORACLE_ADDRESS || '0xDa4AE8301262BdAaf1bb68EC91259E6C512A9A2B'
const ORACLE_CONET = process.env.CONET_BEAMIO_ORACLE_ADDRESS || '0x06a1e0D55B4db57Aa906Eff332902F5CA7a25dd4'

async function checkOracle(label: string, rpcUrl: string, oracleAddr: string) {
	const provider = new ethers.JsonRpcProvider(rpcUrl)
	const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, provider)

	console.log(`\n========== ${label} ==========`)
	console.log(`RPC: ${rpcUrl}`)
	console.log(`Oracle: ${oracleAddr}`)

	const results: { id: number; symbol: string; rate: string; ok: boolean }[] = []

	for (let id = 0; id <= 9; id++) {
		const symbol = CURRENCIES[id] ?? `ID${id}`
		try {
			const rate = await oracle.getRate(id)
			const ok = rate > 0n
			results.push({ id, symbol, rate: rate.toString(), ok })
		} catch (e: any) {
			results.push({ id, symbol, rate: '(revert)', ok: false })
		}
	}

	for (const r of results) {
		const status = r.ok ? '✅' : '❌'
		const human = r.ok && r.rate.length > 10 ? ethers.formatEther(r.rate).slice(0, 12) + '...' : r.rate
		console.log(`  ${r.symbol.padEnd(6)} (${r.id}): ${human.padEnd(20)} ${status}`)
	}

	const missing = results.filter((r) => !r.ok).map((r) => r.symbol)
	if (missing.length > 0) {
		console.log(`  ⚠️ 缺失: ${missing.join(', ')}`)
	} else {
		console.log(`  ✅ 全部 10 种货币已配置`)
	}

	return results
}

async function main() {
	console.log('BeamioOracle 数据完整性检查 (Base + CoNET)')
	console.log('==========================================')

	const [baseResults, conetResults] = await Promise.all([
		checkOracle('Base', BASE_RPC, ORACLE_BASE),
		checkOracle('CoNET', CONET_RPC, ORACLE_CONET),
	])

	// 对比两链
	const baseOk = baseResults.filter((r) => r.ok).length
	const conetOk = conetResults.filter((r) => r.ok).length

	console.log('\n========== 汇总 ==========')
	console.log(`Base:  ${baseOk}/10 已配置`)
	console.log(`CoNET: ${conetOk}/10 已配置`)

	if (baseOk < 10 || conetOk < 10) {
		console.log('\n若 GuardianOracle 已重启，请等待下一轮喂价（约 10 分钟）。')
		console.log('缺失 ETH(9) 会导致 convertGasWeiToUSDC6 失败。')
		process.exit(1)
	}

	console.log('\n✅ 两链 Oracle 数据完整')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
