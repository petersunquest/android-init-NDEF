/**
 * Blockscout v2 verify for AdminStats Referrer Registry views stack:
 * ReferrerRegistryLib + BeamioUserCardReferrerLib + AdminStatsReferrerViews + AdminStatsQueryModuleV6
 *
 * Prereq:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs ReferrerRegistryLib --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardReferrerLib --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsReferrerViews --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV6 --full
 *
 * Usage:
 *   CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyAdminStatsReferrerRegistryViewsConet.ts
 */
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { spawnSync } from 'child_process'
import { FormData, File } from 'undici'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.join(__dirname, '..')
const SCAN = 'https://mainnet.conet.network'
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const COMPILER = process.env.CONET_SOLC_VERSION || 'v0.8.35+commit.47b9dedd'
const SOLC =
	process.env.SOLC ||
	`${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd`

const snap = JSON.parse(
	fs.readFileSync(path.join(root, 'deployments/conet-AdminStatsReferrerRegistryViews.json'), 'utf-8'),
) as {
	referrerRegistryLib: string
	beamioUserCardReferrerLib: string
	adminStatsReferrerViews: string
	adminStatsQueryModule: string
	adminStatsV5: string
	libraryLinks: Record<string, string>
}

type Target = {
	key: string
	address: string
	fullRel: string
	sourceKey: string
	contractName: string
	libraries?: Record<string, Record<string, string>>
}

const TARGETS: Target[] = [
	{
		key: 'ReferrerRegistryLib',
		address: snap.referrerRegistryLib,
		fullRel: 'deployments/base-ReferrerRegistryLib-standard-input-FULL.json',
		sourceKey: 'project/src/BeamioUserCard/ReferrerRegistryLib.sol',
		contractName: 'project/src/BeamioUserCard/ReferrerRegistryLib.sol:ReferrerRegistryLib',
	},
	{
		key: 'BeamioUserCardReferrerLib',
		address: snap.beamioUserCardReferrerLib,
		fullRel: 'deployments/base-BeamioUserCardReferrerLib-standard-input-FULL.json',
		sourceKey: 'project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol',
		contractName: 'project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol:BeamioUserCardReferrerLib',
		libraries: {
			'project/src/BeamioUserCard/ReferrerRegistryLib.sol': {
				ReferrerRegistryLib: snap.referrerRegistryLib,
			},
		},
	},
	{
		key: 'AdminStatsReferrerViews',
		address: snap.adminStatsReferrerViews,
		fullRel: 'deployments/base-AdminStatsReferrerViews-standard-input-FULL.json',
		sourceKey: 'project/src/BeamioUserCard/AdminStatsReferrerViews.sol',
		contractName:
			'project/src/BeamioUserCard/AdminStatsReferrerViews.sol:BeamioUserCardAdminStatsReferrerViews',
		libraries: {
			'project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol': {
				BeamioUserCardReferrerLib: snap.beamioUserCardReferrerLib,
			},
		},
	},
	{
		key: 'AdminStatsQueryModuleV6',
		address: snap.adminStatsQueryModule,
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

function prune(full: any, rootKey: string, libraries?: Target['libraries']) {
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
	if (libraries) settings.libraries = libraries
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

type LocalBytecodeResult = {
	bytecode: string
	immutableReferences?: Record<string, Array<{ start: number; length: number }>>
}

function localDeployedBytecode(
	prunedPath: string,
	sourceKey: string,
	contractSymbol: string,
): LocalBytecodeResult {
	if (!fs.existsSync(SOLC)) {
		console.warn(`[precheck] solc missing at ${SOLC}; skip local bytecode match`)
		return { bytecode: '' }
	}
	const res = spawnSync(SOLC, ['--standard-json', prunedPath], {
		encoding: 'utf-8',
		maxBuffer: 64 * 1024 * 1024,
	})
	if (res.status !== 0) {
		throw new Error(`solc failed: ${res.stderr || res.stdout}`)
	}
	const out = JSON.parse(res.stdout)
	const deployed = out?.contracts?.[sourceKey]?.[contractSymbol]?.evm?.deployedBytecode
	const obj = deployed?.object
	if (!obj) {
		const errs = JSON.stringify(out?.errors?.slice?.(0, 3) || out?.errors || 'no bytecode', null, 2)
		throw new Error(`no deployedBytecode for ${sourceKey}:${contractSymbol}\n${errs}`)
	}
	return {
		bytecode: `0x${obj}`.toLowerCase(),
		immutableReferences: deployed?.immutableReferences,
	}
}

/** Left-pad address to 32-byte hex (no 0x) for Solidity immutable slots. */
function addressAsImmutableWord(addr: string): string {
	return addr.replace(/^0x/, '').toLowerCase().padStart(64, '0')
}

function applyImmutableRefs(
	codeHexNo0x: string,
	refs: Array<{ start: number; length: number }> | undefined,
	wordHex64: string,
): string {
	if (!refs?.length) return codeHexNo0x
	let out = codeHexNo0x
	for (const r of refs) {
		const start = r.start * 2
		const len = r.length * 2
		out = out.slice(0, start) + wordHex64.slice(0, len) + out.slice(start + len)
	}
	return out
}

/**
 * AdminStatsQueryModuleV6 embeds constructor immutables (v5, referrerViews).
 * solc --standard-json leaves those slots zero until linked; patch from deploy snapshot.
 */
function patchV6Immutables(
	localHex: string,
	immutableReferences: LocalBytecodeResult['immutableReferences'],
): string {
	if (!immutableReferences) return localHex
	let body = localHex.startsWith('0x') ? localHex.slice(2) : localHex
	const v5Word = addressAsImmutableWord(snap.adminStatsV5)
	const viewsWord = addressAsImmutableWord(snap.adminStatsReferrerViews)
	// Empirically: id "21" = v5, id "23" = referrerViews (solc assignment order).
	body = applyImmutableRefs(body, immutableReferences['21'], v5Word)
	body = applyImmutableRefs(body, immutableReferences['23'], viewsWord)
	return `0x${body}`
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
	const pruned = prune(full, t.sourceKey, t.libraries)
	const outPath = path.join(root, 'deployments', `conet-${t.key}-verify-buildinfo.json`)
	fs.writeFileSync(outPath, JSON.stringify(pruned) + '\n')
	console.log(`wrote ${outPath} sources=${Object.keys(pruned.sources).length}`)

	const symbol = t.contractName.split(':').pop()!
	const localRes = localDeployedBytecode(outPath, t.sourceKey, symbol)
	let local = localRes.bytecode
	const onchain = await ethGetCode(t.address)
	if (local) {
		if (t.key === 'AdminStatsQueryModuleV6') {
			local = patchV6Immutables(local, localRes.immutableReferences)
		}
		const addrHex = t.address.replace(/^0x/, '').toLowerCase().padStart(40, '0')
		let patched = local.startsWith('0x') ? local.slice(2) : local
		const chainBody = onchain.startsWith('0x') ? onchain.slice(2) : onchain
		if (patched.length === chainBody.length) {
			for (let i = 0; i + 40 <= patched.length; i += 2) {
				const slot = patched.slice(i, i + 40)
				const chainSlot = chainBody.slice(i, i + 40)
				if (slot === '0'.repeat(40) && chainSlot === addrHex) {
					patched = patched.slice(0, i) + addrHex + patched.slice(i + 40)
				}
			}
			local = `0x${patched}`
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
	form.set('autodetect_constructor_args', 'true')
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
