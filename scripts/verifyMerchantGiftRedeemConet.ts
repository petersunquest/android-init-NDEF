/**
 * Blockscout v2 verify for Discover Gift redeem stack:
 * RedeemModule + AdminStatsQueryModuleV6 (router)
 *
 * Prereq:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs RedeemModule --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV6 --full
 *
 * Usage:
 *   CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyMerchantGiftRedeemConet.ts
 */
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { spawnSync } from 'child_process'
import { FormData, File } from 'undici'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.join(__dirname, '..')
const SCAN = 'https://mainnet.conet.network'
const RPC = process.env.CONET_RPC_URL || 'https://publicrpc.conet.network'
const COMPILER = process.env.CONET_SOLC_VERSION || 'v0.8.35+commit.47b9dedd'
const SOLC =
	process.env.SOLC ||
	`${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd`

const snap = JSON.parse(
	fs.readFileSync(path.join(root, 'deployments/conet-MerchantGiftRedeem.json'), 'utf-8'),
) as {
	redeemModule?: string
	adminStatsQueryModuleV6?: string
	adminStatsQueryModuleV5?: string
	adminStatsReferrerViews?: string
	modules?: {
		redeemModule?: string
		adminStatsQueryModuleV6?: string
		adminStatsV5?: string
		referrerViews?: string
	}
	constructorArgs?: { v5?: string; referrerViews?: string }
}

const redeemModule = snap.modules?.redeemModule || snap.redeemModule
const adminStatsV6 = snap.modules?.adminStatsQueryModuleV6 || snap.adminStatsQueryModuleV6
const v5Addr =
	snap.modules?.adminStatsV5 || snap.adminStatsQueryModuleV5 || snap.constructorArgs?.v5
const viewsAddr =
	snap.modules?.referrerViews || snap.adminStatsReferrerViews || snap.constructorArgs?.referrerViews
if (!redeemModule || !adminStatsV6 || !v5Addr || !viewsAddr) {
	throw new Error(
		'conet-MerchantGiftRedeem.json must include modules.redeemModule, modules.adminStatsQueryModuleV6, adminStatsV5 + referrerViews',
	)
}

type Target = {
	key: string
	address: string
	fullRel: string
	sourceKey: string
	contractName: string
}

const TARGETS: Target[] = [
	{
		key: 'RedeemModule',
		address: redeemModule,
		fullRel: 'deployments/base-RedeemModule-standard-input-FULL.json',
		sourceKey: 'project/src/BeamioUserCard/RedeemModule.sol',
		contractName: 'project/src/BeamioUserCard/RedeemModule.sol:BeamioUserCardRedeemModuleVNext',
	},
	{
		key: 'AdminStatsQueryModuleV6',
		address: adminStatsV6,
		fullRel: 'deployments/base-AdminStatsQueryModuleV6-standard-input-FULL.json',
		sourceKey: 'project/src/BeamioUserCard/AdminStatsQueryModuleV6.sol',
		contractName:
			'project/src/BeamioUserCard/AdminStatsQueryModuleV6.sol:BeamioUserCardAdminStatsQueryModuleV6',
	},
]

function resolveImport(fromKey: string, spec: string, sources: Record<string, unknown>): string | null {
	if (sources[spec]) return spec
	if (spec.startsWith('@') || spec.startsWith('project/')) {
		return sources[spec] ? spec : null
	}
	const fromDir = path.posix.dirname(fromKey.replace(/^project\//, ''))
	const joined = path.posix.normalize(path.posix.join(fromDir, spec))
	for (const c of [`project/${joined}`, joined]) {
		if (sources[c]) return c
	}
	return null
}

function prune(full: any, rootKey: string) {
	const sources = full.sources as Record<string, { content: string }>
	const keep = new Set<string>()
	const stack = [rootKey]
	while (stack.length) {
		const cur = stack.pop()!
		if (keep.has(cur) || !sources[cur]) continue
		keep.add(cur)
		const content = sources[cur].content || ''
		const importRe = /import\s+(?:[^'"]*\s+from\s+)?["']([^"']+)["']/g
		let m: RegExpExecArray | null
		while ((m = importRe.exec(content))) {
			const resolved = resolveImport(cur, m[1], sources)
			if (resolved && !keep.has(resolved)) stack.push(resolved)
		}
	}
	const prunedSources: Record<string, { content: string }> = {}
	for (const k of keep) prunedSources[k] = sources[k]
	const settings = { ...full.settings }
	delete settings.compilationTarget
	settings.outputSelection = {
		'*': {
			'': ['ast'],
			'*': ['abi', 'evm.bytecode', 'evm.deployedBytecode', 'evm.methodIdentifiers', 'metadata'],
		},
	}
	settings.remappings = []
	return { language: full.language, sources: prunedSources, settings }
}

async function ethGetCode(addr: string): Promise<string> {
	const r = await fetch(RPC, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({
			jsonrpc: '2.0',
			id: 1,
			method: 'eth_getCode',
			params: [addr, 'latest'],
		}),
	})
	const j = (await r.json()) as { result?: string }
	return (j.result || '0x').toLowerCase()
}

function addressAsImmutableWord(addr: string): string {
	return addr.replace(/^0x/, '').toLowerCase().padStart(64, '0')
}

function v6ConstructorArgsHex(): string {
	return `${addressAsImmutableWord(v5Addr)}${addressAsImmutableWord(viewsAddr)}`
}

function patchV6Immutables(localHex: string, onchainHex: string): string {
	const v5Word = addressAsImmutableWord(v5Addr)
	const viewsWord = addressAsImmutableWord(viewsAddr)
	const v5Bare = v5Addr.replace(/^0x/, '').toLowerCase()
	const viewsBare = viewsAddr.replace(/^0x/, '').toLowerCase()
	const chainBody = onchainHex.startsWith('0x') ? onchainHex.slice(2) : onchainHex
	let body = localHex.startsWith('0x') ? localHex.slice(2) : localHex
	if (body.length !== chainBody.length) return localHex
	for (let i = 0; i + 64 <= body.length; i += 2) {
		const slot = body.slice(i, i + 64)
		const chainSlot = chainBody.slice(i, i + 64)
		if (slot === '0'.repeat(64) && (chainSlot === v5Word || chainSlot.endsWith(v5Bare))) {
			body = body.slice(0, i) + v5Word + body.slice(i + 64)
		} else if (slot === '0'.repeat(64) && (chainSlot === viewsWord || chainSlot.endsWith(viewsBare))) {
			body = body.slice(0, i) + viewsWord + body.slice(i + 64)
		}
	}
	return `0x${body}`
}

function localDeployedBytecode(prunedPath: string, sourceKey: string, contractSymbol: string): string {
	if (!fs.existsSync(SOLC)) {
		console.warn(`[precheck] solc missing at ${SOLC}; skip local bytecode match`)
		return ''
	}
	const res = spawnSync(SOLC, ['--standard-json', prunedPath], {
		encoding: 'utf-8',
		maxBuffer: 64 * 1024 * 1024,
	})
	if (res.status !== 0) {
		throw new Error(`solc failed: ${res.stderr || res.stdout}`)
	}
	const out = JSON.parse(res.stdout)
	const obj = out?.contracts?.[sourceKey]?.[contractSymbol]?.evm?.deployedBytecode?.object
	if (!obj) {
		const errs = JSON.stringify(out?.errors?.slice?.(0, 3) || out?.errors || 'no bytecode', null, 2)
		throw new Error(`no deployedBytecode for ${sourceKey}:${contractSymbol}\n${errs}`)
	}
	return `0x${obj}`.toLowerCase()
}

async function isVerified(addr: string): Promise<boolean> {
	const r = await fetch(`${SCAN}/api/v2/smart-contracts/${addr}`)
	if (!r.ok) return false
	const d = (await r.json()) as {
		is_verified?: boolean
		is_partially_verified?: boolean
		source_code?: string
	}
	return Boolean(d.is_verified || d.is_partially_verified || (d.source_code && d.source_code.length > 20))
}

async function verifyOne(t: Target): Promise<void> {
	console.log(`\n=== ${t.key} ${t.address} ===`)
	if (await isVerified(t.address)) {
		console.log('already verified')
		return
	}
	const fullPath = path.join(root, t.fullRel)
	if (!fs.existsSync(fullPath)) throw new Error(`Missing ${t.fullRel} — run export --full first`)
	const full = JSON.parse(fs.readFileSync(fullPath, 'utf-8'))
	const pruned = prune(full, t.sourceKey)
	const outPath = path.join(root, 'deployments', `conet-${t.key}-verify-buildinfo.json`)
	fs.writeFileSync(outPath, JSON.stringify(pruned) + '\n')
	console.log(`wrote ${outPath} sources=${Object.keys(pruned.sources).length}`)

	const symbol = t.contractName.split(':').pop()!
	let local = localDeployedBytecode(outPath, t.sourceKey, symbol)
	const onchain = await ethGetCode(t.address)
	if (local) {
		if (t.key === 'AdminStatsQueryModuleV6') {
			local = patchV6Immutables(local, onchain)
		}
		if (local !== onchain) {
			console.error(`bytecode mismatch localLen=${local.length} chainLen=${onchain.length}`)
			console.error(`localTail=${local.slice(-24)} chainTail=${onchain.slice(-24)}`)
			throw new Error(`${t.key}: local solc deployedBytecode != eth_getCode — abort submit`)
		}
		console.log('local bytecode matches chain ✅')
	}

	const form = new FormData()
	form.set('compiler_version', COMPILER)
	form.set('contract_name', t.contractName)
	if (t.key === 'AdminStatsQueryModuleV6') {
		form.set('autodetect_constructor_args', 'false')
		form.set('constructor_args', v6ConstructorArgsHex())
	} else {
		form.set('autodetect_constructor_args', 'true')
	}
	form.set('license_type', 'mit')
	form.set(
		'files[0]',
		new File([JSON.stringify(pruned)], `${t.key}.json`, { type: 'application/json' }),
	)
	const url = `${SCAN}/api/v2/smart-contracts/${t.address}/verification/via/standard-input`
	const res = await fetch(url, { method: 'POST', body: form as any })
	const text = await res.text()
	console.log(`submit → HTTP ${res.status}: ${text.slice(0, 400)}`)

	const max = Number(process.env.CONET_VERIFY_POLL_MAX || 90)
	for (let i = 0; i < max; i++) {
		await new Promise((r) => setTimeout(r, 4000))
		if (await isVerified(t.address)) {
			console.log(`verified ${t.address}`)
			return
		}
		process.stdout.write('.')
	}
	throw new Error(`poll timeout ${t.key} ${t.address}`)
}

async function main() {
	const only = (process.env.CONET_VERIFY_ONLY || '')
		.split(',')
		.map((s) => s.trim())
		.filter(Boolean)
	const list = only.length ? TARGETS.filter((t) => only.includes(t.key)) : TARGETS
	for (const t of list) {
		await verifyOne(t)
	}
	console.log('\nAll done')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
