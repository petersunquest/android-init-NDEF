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

type LibLinks = {
	BeamioUserCardFormattingLib: string
	BeamioUserCardTransferLib: string
	BeamioUserCardViewsLib: string
	BeamioUserCardGatewayMintLib?: string
	BeamioUserCardModuleRouterLib?: string
	BeamioUserCardAdminGatewayLib?: string
	BeamioUserCardRedeemGatewayLib?: string
	BeamioUserCardUpdateLib?: string
	BeamioUserCardReferrerLib?: string
	ReferrerRegistryLib?: string
	BeamioUserCardTierOpsLib?: string
	MembershipFeeOpsLib?: string
}

const snap = JSON.parse(
	fs.readFileSync(path.join(root, 'deployments/conet-UserCardBeacon.json'), 'utf-8'),
) as {
	impl: string
	beacon: string
	libraryLinks: LibLinks
	issuedNftModule?: string
	reusedLibraries?: Record<string, boolean>
}

type Target = {
	key: string
	address: string
	fullRel: string
	artifactRel: string
	sourceKey: string
	contractName: string
	libraries?: Record<string, Record<string, string>>
}

const TARGETS: Target[] = []
const L = snap.libraryLinks

function maybeLib(
	key: string,
	address: string | undefined,
	file: string,
	symbol: string,
	libraries?: Target['libraries'],
): void {
	if (!address) {
		console.log(`[skip] ${key} not in snap.libraryLinks`)
		return
	}
	if (snap.reusedLibraries?.[key]) {
		console.log(`[skip] ${key} reused existing runtime ${address}`)
		return
	}
	TARGETS.push({
		key,
		address,
		fullRel: `deployments/base-${key}-standard-input-FULL.json`,
		artifactRel: `src/BeamioUserCard/${file}/${symbol}.json`,
		sourceKey: `project/src/BeamioUserCard/${file}`,
		contractName: `project/src/BeamioUserCard/${file}:${symbol}`,
		libraries,
	})
}

// Nested first (registry → referrer → update), then plain UserCard libs, then impl.
maybeLib('MembershipFeeOpsLib', L.MembershipFeeOpsLib, 'MembershipFeeOpsLib.sol', 'MembershipFeeOpsLib')
maybeLib(
	'BeamioUserCardTierOpsLib',
	L.BeamioUserCardTierOpsLib,
	'BeamioUserCardTierOpsLib.sol',
	'BeamioUserCardTierOpsLib',
	{
		'project/src/BeamioUserCard/MembershipFeeOpsLib.sol': {
			MembershipFeeOpsLib: L.MembershipFeeOpsLib!,
		},
	},
)
maybeLib('ReferrerRegistryLib', L.ReferrerRegistryLib, 'ReferrerRegistryLib.sol', 'ReferrerRegistryLib')
maybeLib('BeamioUserCardReferrerLib', L.BeamioUserCardReferrerLib, 'BeamioUserCardReferrerLib.sol', 'BeamioUserCardReferrerLib', {
	'project/src/BeamioUserCard/ReferrerRegistryLib.sol': {
		ReferrerRegistryLib: L.ReferrerRegistryLib!,
	},
})
maybeLib('BeamioUserCardUpdateLib', L.BeamioUserCardUpdateLib, 'BeamioUserCardUpdateLib.sol', 'BeamioUserCardUpdateLib', {
	'project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol': {
		BeamioUserCardReferrerLib: L.BeamioUserCardReferrerLib!,
	},
	'project/src/BeamioUserCard/BeamioUserCardTransferLib.sol': {
		BeamioUserCardTransferLib: L.BeamioUserCardTransferLib,
	},
})
maybeLib('BeamioUserCardFormattingLib', L.BeamioUserCardFormattingLib, 'BeamioUserCardFormattingLib.sol', 'BeamioUserCardFormattingLib')
maybeLib('BeamioUserCardTransferLib', L.BeamioUserCardTransferLib, 'BeamioUserCardTransferLib.sol', 'BeamioUserCardTransferLib')
maybeLib('BeamioUserCardViewsLib', L.BeamioUserCardViewsLib, 'BeamioUserCardViewsLib.sol', 'BeamioUserCardViewsLib')
maybeLib('BeamioUserCardGatewayMintLib', L.BeamioUserCardGatewayMintLib, 'BeamioUserCardGatewayMintLib.sol', 'BeamioUserCardGatewayMintLib')
maybeLib('BeamioUserCardModuleRouterLib', L.BeamioUserCardModuleRouterLib, 'BeamioUserCardModuleRouterLib.sol', 'BeamioUserCardModuleRouterLib')
maybeLib('BeamioUserCardAdminGatewayLib', L.BeamioUserCardAdminGatewayLib, 'BeamioUserCardAdminGatewayLib.sol', 'BeamioUserCardAdminGatewayLib')
maybeLib('BeamioUserCardRedeemGatewayLib', L.BeamioUserCardRedeemGatewayLib, 'BeamioUserCardRedeemGatewayLib.sol', 'BeamioUserCardRedeemGatewayLib')
if (snap.issuedNftModule) {
	TARGETS.push({
		key: 'BeamioUserCardIssuedNftModuleV2',
		address: snap.issuedNftModule,
		fullRel: 'deployments/base-BeamioUserCardIssuedNftModuleV2-standard-input-FULL.json',
		artifactRel: 'src/BeamioUserCard/IssuedNftModuleV2.sol/BeamioUserCardIssuedNftModuleV2.json',
		sourceKey: 'project/src/BeamioUserCard/IssuedNftModuleV2.sol',
		contractName:
			'project/src/BeamioUserCard/IssuedNftModuleV2.sol:BeamioUserCardIssuedNftModuleV2',
	})
}

const cardLibraries: Record<string, Record<string, string>> = {
	'project/src/BeamioUserCard/BeamioUserCardFormattingLib.sol': {
		BeamioUserCardFormattingLib: L.BeamioUserCardFormattingLib,
	},
	'project/src/BeamioUserCard/BeamioUserCardTransferLib.sol': {
		BeamioUserCardTransferLib: L.BeamioUserCardTransferLib,
	},
	'project/src/BeamioUserCard/BeamioUserCardViewsLib.sol': {
		BeamioUserCardViewsLib: L.BeamioUserCardViewsLib,
	},
}
if (L.BeamioUserCardGatewayMintLib) {
	cardLibraries['project/src/BeamioUserCard/BeamioUserCardGatewayMintLib.sol'] = {
		BeamioUserCardGatewayMintLib: L.BeamioUserCardGatewayMintLib,
	}
}
if (L.BeamioUserCardModuleRouterLib) {
	cardLibraries['project/src/BeamioUserCard/BeamioUserCardModuleRouterLib.sol'] = {
		BeamioUserCardModuleRouterLib: L.BeamioUserCardModuleRouterLib,
	}
}
if (L.BeamioUserCardAdminGatewayLib) {
	cardLibraries['project/src/BeamioUserCard/BeamioUserCardAdminGatewayLib.sol'] = {
		BeamioUserCardAdminGatewayLib: L.BeamioUserCardAdminGatewayLib,
	}
}
if (L.BeamioUserCardRedeemGatewayLib) {
	cardLibraries['project/src/BeamioUserCard/BeamioUserCardRedeemGatewayLib.sol'] = {
		BeamioUserCardRedeemGatewayLib: L.BeamioUserCardRedeemGatewayLib,
	}
}
if (L.BeamioUserCardTierOpsLib) {
	cardLibraries['project/src/BeamioUserCard/BeamioUserCardTierOpsLib.sol'] = {
		BeamioUserCardTierOpsLib: L.BeamioUserCardTierOpsLib,
	}
}
if (L.BeamioUserCardUpdateLib) {
	cardLibraries['project/src/BeamioUserCard/BeamioUserCardUpdateLib.sol'] = {
		BeamioUserCardUpdateLib: L.BeamioUserCardUpdateLib,
	}
}
if (L.BeamioUserCardReferrerLib) {
	cardLibraries['project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol'] = {
		BeamioUserCardReferrerLib: L.BeamioUserCardReferrerLib,
	}
}
if (L.ReferrerRegistryLib) {
	cardLibraries['project/src/BeamioUserCard/ReferrerRegistryLib.sol'] = {
		ReferrerRegistryLib: L.ReferrerRegistryLib,
	}
}
if (L.MembershipFeeOpsLib) {
	cardLibraries['project/src/BeamioUserCard/MembershipFeeOpsLib.sol'] = {
		MembershipFeeOpsLib: L.MembershipFeeOpsLib,
	}
}

TARGETS.push({
	key: 'BeamioUserCard',
	address: snap.impl,
	fullRel: 'deployments/base-BeamioUserCard-standard-input-FULL.json',
	artifactRel: 'src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json',
	sourceKey: 'project/src/BeamioUserCard/BeamioUserCard.sol',
	contractName: 'project/src/BeamioUserCard/BeamioUserCard.sol:BeamioUserCard',
	libraries: cardLibraries,
})

TARGETS.push({
	key: 'BeamioUserCardUpgradeableBeacon',
	address: snap.beacon,
	fullRel: 'deployments/base-BeamioUserCardUpgradeableBeacon-standard-input-FULL.json',
	artifactRel:
		'src/BeamioUserCard/BeamioUserCardUpgradeableBeacon.sol/BeamioUserCardUpgradeableBeacon.json',
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
	const res = spawnSync(solcPath, ['--standard-json'], {
		encoding: 'utf-8',
		maxBuffer: 64 * 1024 * 1024,
		input: fs.readFileSync(prunedPath, 'utf-8'),
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

function materializeLibrarySelfAddress(local: string, target: Target): string {
	const artifactPath = path.join(root, 'artifacts', target.artifactRel)
	if (!fs.existsSync(artifactPath)) return local
	const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf-8')) as {
		immutableReferences?: Record<string, Array<{ start: number; length: number }>>
	}
	const references = artifact.immutableReferences?.library_deploy_address ?? []
	if (references.length === 0) return local

	let body = local.replace(/^0x/, '')
	const address = target.address.replace(/^0x/, '').toLowerCase()
	for (const { start, length } of references) {
		if (length < 20) throw new Error(`${target.key}: unexpected library self-address length ${length}`)
		const replacement = `${'0'.repeat((length - 20) * 2)}${address}`
		const startHex = start * 2
		const endHex = startHex + length * 2
		const original = body.slice(startHex, endHex)
		if (original === '0'.repeat(length * 2)) {
			body = body.slice(0, startHex) + replacement + body.slice(endHex)
		} else if (original !== replacement) {
			throw new Error(`${target.key}: unexpected non-zero library self-address placeholder`)
		}
	}
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

	const onchain = await ethGetCode(t.address)
	const { compiler, solcPath } = probeSolc(onchain)
	console.log(`compiler=${compiler} tail=${onchain.slice(-24)}`)

	const symbol = t.contractName.split(':').pop()!
	let local = localDeployedBytecode(solcPath, outPath, t.sourceKey, symbol)
	if (local) {
		local = materializeLibrarySelfAddress(local, t).toLowerCase()
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
