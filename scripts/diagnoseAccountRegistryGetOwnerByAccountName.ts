/**
 * 诊断 AccountRegistry 链上 getOwnerByAccountName 行为
 *
 * 输出：
 *  1. 合约是否真的部署在 conet-addresses.json AccountRegistry 地址上（eth_getCode）
 *  2. selector 0x... 是否在 ABI 中（本地 ABI 自检）
 *  3. 已注册名字（默认 rrr0，可由 KNOWN_NAME 环境变量覆盖）→ 返回值
 *  4. 一定不存在的随机名字 → 返回什么（ZeroAddress / 0x revert / BAD_DATA）
 *  5. 反查 getAccount(owner) 是否能正常返回
 *
 * Run: npx tsx scripts/diagnoseAccountRegistryGetOwnerByAccountName.ts
 */
import { ethers } from 'ethers'
import * as fs from 'fs'
import * as path from 'path'
import { fileURLToPath } from 'url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const RPC = process.env.CONET_RPC || 'https://rpc1.conet.network'
const ADDRESSES_PATH = path.join(__dirname, '..', 'deployments', 'conet-addresses.json')
const ABI_PATH = path.join(__dirname, '..', 'src', 'x402sdk', 'src', 'ABI', 'beamio-AccountRegistry.json')

const KNOWN_NAME = process.env.KNOWN_NAME || 'rrr0'

async function main() {
	const addrs = JSON.parse(fs.readFileSync(ADDRESSES_PATH, 'utf-8'))
	const REG_ADDR: string = process.env.REGISTRY_ADDRESS || addrs.AccountRegistry
	if (!REG_ADDR) throw new Error('未解析到 AccountRegistry 地址')
	const abi = JSON.parse(fs.readFileSync(ABI_PATH, 'utf-8'))

	const provider = new ethers.JsonRpcProvider(RPC)
	const reg = new ethers.Contract(REG_ADDR, abi, provider)

	console.log('='.repeat(70))
	console.log('AccountRegistry getOwnerByAccountName 诊断')
	console.log('='.repeat(70))
	console.log('RPC:', RPC)
	console.log('AccountRegistry:', REG_ADDR)

	// 1. eth_getCode
	const code = await provider.getCode(REG_ADDR)
	const codeLen = (code.length - 2) / 2
	console.log(`\n[1] eth_getCode bytes=${codeLen} ${codeLen === 0 ? '❌ 该地址无合约代码（地址错误或未部署）' : '✅'}`)
	if (codeLen === 0) return

	// 2. ABI 自检：selector + ABI 函数定义
	const iface = new ethers.Interface(abi as any)
	const sig = 'getOwnerByAccountName(string)'
	const selector = ethers.id(sig).slice(0, 10)
	const hasFn = !!iface.fragments.find(f => f.type === 'function' && (f as any).name === 'getOwnerByAccountName')
	console.log(`\n[2] 本地 ABI selector ${selector} (${sig}) ${hasFn ? '✅ 存在' : '❌ 缺失'}`)

	// 3. 已注册名字
	console.log(`\n[3] 已注册名字探测：getOwnerByAccountName("${KNOWN_NAME}")`)
	try {
		const owner: string = await reg.getOwnerByAccountName(KNOWN_NAME)
		console.log(`    → ${owner} ${owner === ethers.ZeroAddress ? '⚠️ 返回 ZeroAddress（说明该名字未注册）' : '✅ 解码成功'}`)

		if (owner !== ethers.ZeroAddress) {
			// 5. 反查 getAccount(owner)
			console.log(`\n[5] 反查 getAccount(${owner})`)
			try {
				const acc = await (reg as any).getAccount(owner)
				console.log(`    → exists=${acc?.exists} accountName="${acc?.accountName}" createdAt=${acc?.createdAt?.toString?.()}`)
			} catch (ex: any) {
				console.log(`    ❌ getAccount 失败: code=${ex?.code} msg=${ex?.shortMessage || ex?.message}`)
			}
		}
	} catch (ex: any) {
		console.log(`    ❌ 调用失败: code=${ex?.code} msg=${ex?.shortMessage || ex?.message}`)
		console.log(`    → 这表示链上对该名字返回 0x（合约未实现 selector，或函数未 return）。`)
		// 同时用 raw eth_call 看到底回什么
		try {
			const data = selector + ethers.AbiCoder.defaultAbiCoder().encode(['string'], [KNOWN_NAME]).slice(2)
			const raw = await provider.call({ to: REG_ADDR, data })
			console.log(`    raw eth_call result = ${raw} (length=${(raw.length - 2) / 2} bytes)`)
		} catch (ce: any) {
			console.log(`    raw eth_call revert: ${ce?.shortMessage || ce?.message}`)
		}
	}

	// 4. 一定不存在的随机名字
	const randomName = `__nonexistent_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`
	console.log(`\n[4] 不存在名字探测：getOwnerByAccountName("${randomName}")`)
	try {
		const owner: string = await reg.getOwnerByAccountName(randomName)
		console.log(`    → ${owner} ${owner === ethers.ZeroAddress ? '✅ 返回 ZeroAddress（合约对未注册名字返回 0x0…0，正常）' : '⚠️ 返回非零地址'}`)
	} catch (ex: any) {
		console.log(`    ⚠️ ethers 抛错: code=${ex?.code} msg=${ex?.shortMessage || ex?.message}`)
		try {
			const data = selector + ethers.AbiCoder.defaultAbiCoder().encode(['string'], [randomName]).slice(2)
			const raw = await provider.call({ to: REG_ADDR, data })
			const rawLen = (raw.length - 2) / 2
			console.log(`    raw eth_call result = ${raw} (length=${rawLen} bytes)`)
			if (rawLen === 0) {
				console.log(`    → 链上对未注册名字直接返回 0x（空 bytes），符合 ethers BAD_DATA 触发条件。`)
				console.log(`      这说明合约 getOwnerByAccountName 内部对 mapping 缺失走了一条不 return 的分支（或 require/revert without data）。`)
				console.log(`      最稳妥的客户端处理：catch BAD_DATA 视为 ZeroAddress（已经在 db.ts isOnchainEmptyResult 实现）。`)
			}
		} catch (ce: any) {
			console.log(`    raw eth_call revert: ${ce?.shortMessage || ce?.message}`)
		}
	}

	console.log('\n='.repeat(70))
}

main().catch(e => { console.error(e); process.exit(1) })
