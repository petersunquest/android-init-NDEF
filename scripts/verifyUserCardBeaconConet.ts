/**
 * Blockscout v2 verify for CoNET UserCard beacon stack:
 * optional new libs + sentinel impl + UpgradeableBeacon.
 *
 * Prereq: deployments/conet-UserCardBeacon.json + FULL Standard JSON exports.
 *
 * Usage:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCard --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardUpgradeableBeacon --full
 *   # plus any newly deployed libs
 *   npx tsx scripts/verifyUserCardBeaconConet.ts
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

const snap = JSON.parse(
	fs.readFileSync(path.join(root, 'deployments/conet-UserCardBeacon.json'), 'utf-8'),
) as {
	impl: string
	beacon: string
	libraryLinks: {
		BeamioUserCardFormattingLib: string
		BeamioUserCardTransferLib: string
		BeamioUserCardViewsLib: string
	}
	reusedLibraries?: Record<string, boolean>
}

type Target = {
	key: string
	address: string
	fullRel: string
	sourceKey: string
	contractName: string
	libraries?: Record<string, Record<string, string>>
}

const TARGETS: Target[] = []

function maybeLib(key: string, address: string, file: string, symbol: string): void {
	if (snap.reusedLibraries?.[key]) {
		console.log(`[skip] ${key} reused existing runtime ${address}`)
		return
	}
	TARGETS.push({
		key,
		address,
		fullRel: `deployments/base-${key}-standard-input-FULL.json`,
		sourceKey: `project/src/BeamioUserCard/${file}`,
		contractName: `project/src/BeamioUserCard/${file}:${symbol}`,
	})
}

maybeLib(
	'BeamioUserCardFormattingLib',
	snap.libraryLinks.BeamioUserCardFormattingLib,
	'BeamioUserCardFormattingLib.sol',
	'BeamioUserCardFormattingLib',
)
maybeLib(
	'BeamioUserCardTransferLib',
	snap.libraryLinks.BeamioUserCardTransferLib,
	'BeamioUserCardTransferLib.sol',
	'BeamioUserCardTransferLib',
)
maybeLib(
	'BeamioUserCardViewsLib',
	snap.libraryLinks.BeamioUserCardViewsLib,
	'BeamioUserCardViewsLib.sol',
	'BeamioUserCardViewsLib',
)

TARGETS.push({
	key: 'BeamioUserCard',
	address: snap.impl,
	fullRel: 'deployments/base-BeamioUserCard-standard-input-FULL.json',
	sourceKey: 'project/src/BeamioUserCard/BeamioUserCard.sol',
	contractName: 'project/src/BeamioUserCard/BeamioUserCard.sol:BeamioUserCard',
	libraries: {
		'project/src/BeamioUserCard/BeamioUserCardFormattingLib.sol': {
			BeamioUserCardFormattingLib: snap.libraryLinks.BeamioUserCardFormattingLib,
		},
		'project/src/BeamioUserCard/BeamioUserCardTransferLib.sol': {
			BeamioUserCardTransferLib: snap.libraryLinks.BeamioUserCardTransferLib,
		},
		'project/src/BeamioUserCard/BeamioUserCardViewsLib.sol': {
			BeamioUserCardViewsLib: snap.libraryLinks.BeamioUserCardViewsLib,
		},
	},
})

TARGETS.push({
	key: 'BeamioUserCardUpgradeableBeacon',
	address: snap.beacon,
	fullRel: 'deployments/base-BeamioUserCardUpgradeableBeacon-standard-input-FULL.json',
	sourceKey: 'project/src/BeamioUserCard/BeamioUserCardUpgradeableBeacon.sol',
	contractName:
		'project/src/BeamioUserCard/BeamioUserCardUpgradeableBeacon.sol:BeamioUserCardUpgradeableBeacon',
})

function remapImport(spec: string, remappings: string[], sources: Record<string, unknown>): string | null {
	for (const r of remappings) {
		const eq = r.indexOf('=')
		if (eq < 0) continue
		const left = r.slice(0, eq)
		const right = r.slice(eq + 1)
		const colon = left.lastIndexOf(':')
		const prefix = colon >= 0 ? left.slice(colon + 1) : left
		if (!spec.startsWith(prefix)) continue
		const mapped = `${right}${spec.slice(prefix.length)}`
		if (sources[mapped]) return mapped
	}
	if (spec.startsWith('@openzeppelin/contracts/')) {
		const suffix = spec.slice('@openzeppelin/contracts/'.length)
		for (const k of Object.keys(sources)) {
			if (k.startsWith('npm/@openzeppelin/contracts@') && k.endsWith(`/${suffix}`)) return k
		}
	}
	return null
}

function resolveImport(
	fromKey: string,
	spec: string,
	sources: Record<string, unknown>,
	remappings: string[],
): string | null {
	if (sources[spec]) return spec
	const remapped = remapImport(spec, remappings, sources)
	if (remapped) return remapped
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

function normalizeNpmSourceKeys(
	sources: Record<string, { content: string }>,
): Record<string, { content: string }> {
	const next: Record<string, { content: string }> = {}
	for (const [k, v] of Object.entries(sources)) {
		const m = k.match(/^npm\/@openzeppelin\/contracts@[^/]+\/(.+)$/)
		next[m ? `@openzeppelin/contracts/${m[1]}` : k] = v
	}
	return next
}

function prune(full: any, rootKey: string, libraries?: Target['libraries']) {
	const sources = full.sources as Record<string, { content: string }>
	const remappings = Array.isArray(full.settings?.remappings) ? full.settings.remappings : []
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
			const resolved = resolveImport(cur, m[1], sources, remappings)
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
	return {
		language: full.language,
		sources: normalizeNpmSourceKeys(prunedSources),
		settings,
	}
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

function probeSolc(code: string): { compiler: string; solcPath: string } {
	const body = code.startsWith('0x') ? code.slice(2) : code
	const marker = '64736f6c6343'
	const idx = body.lastIndexOf(marker)
	let tag = '000823'
	if (idx >= 0 && idx + 12 + 6 <= body.length) {
		tag = body.slice(idx + 12, idx + 18)
	}
	const map: Record<string, { compiler: string; file: string }> = {
		'000823': { compiler: 'v0.8.35+commit.47b9dedd', file: 'solc-macosx-amd64-v0.8.35+commit.47b9dedd' },
		'000821': { compiler: 'v0.8.33+commit.64118f21', file: 'solc-macosx-amd64-v0.8.33+commit.64118f21' },
		'00081b': { compiler: 'v0.8.27+commit.40f1eb3f', file: 'solc-macosx-amd64-v0.8.27+commit.40f1eb3f' },
	}
	const hit = map[tag] || map['000823']
	const solcPath =
		process.env.SOLC ||
		`${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/${hit.file}`
	return { compiler: process.env.CONET_SOLC_VERSION || hit.compiler, solcPath }
}

function localDeployedBytecode(
	solcPath: string,
	prunedPath: string,
	sourceKey: string,
	contractSymbol: string,
): string {
	if (!fs.existsSync(solcPath)) {
		console.warn(`[precheck] solc missing at ${solcPath}; skip local bytecode match`)
		return ''
	}
	const res = spawnSync(solcPath, ['--standard-json', prunedPath], {
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
	const pruned = prune(full, t.sourceKey, t.libraries)
	const outPath = path.join(root, 'deployments', `conet-${t.key}-verify-buildinfo.json`)
	fs.writeFileSync(outPath, JSON.stringify(pruned) + '\n')
	console.log(`wrote ${outPath} sources=${Object.keys(pruned.sources).length}`)

	const onchain = await ethGetCode(t.address)
	const { compiler, solcPath } = probeSolc(onchain)
	console.log(`compiler=${compiler} tail=${onchain.slice(-24)}`)

	const symbol = t.contractName.split(':').pop()!
	let local = localDeployedBytecode(solcPath, outPath, t.sourceKey, symbol)
	if (local) {
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
	form.set('compiler_version', compiler)
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
