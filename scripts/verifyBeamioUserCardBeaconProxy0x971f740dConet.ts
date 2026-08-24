/**
 * Verify merchant BeaconProxy card 0x971f740d…7e71 on CoNET Blockscout.
 *
 * This is BeamioUserCardBeaconProxy (thin OZ BeaconProxy), not CREATE UserCard.
 * Constructor: (address beacon, bytes initializeCalldata) — taken from create tx
 * 0x61f38143dc795c9f7fcdc152722ca7e9576b56955ca7b3da0028ba4f94f8258d
 *
 * Prereq: deployments/base-BeamioUserCardBeaconProxy-standard-input-FULL.json
 *
 * Usage:
 *   npx tsx scripts/verifyBeamioUserCardBeaconProxy0x971f740dConet.ts
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

const ADDR = '0x971f740d78b2602A5aE163C535e52cED54ED7e71'
const BEACON = '0x01716C6b755a0FBfCF4e548A6d6B7af19ADf6698'
const SOURCE_KEY = 'project/src/BeamioUserCard/BeamioUserCardBeaconProxy.sol'
const CONTRACT = `${SOURCE_KEY}:BeamioUserCardBeaconProxy`
const FULL_REL = 'deployments/base-BeamioUserCardBeaconProxy-standard-input-FULL.json'
const PRUNED_REL = 'deployments/conet-BeamioUserCardBeaconProxy-0x971f740d-verify-buildinfo.json'
const CTOR_REL = 'deployments/conet-BeamioUserCardBeaconProxy-0x971f740d-constructor-args.txt'
const CREATE_TX = '0x61f38143dc795c9f7fcdc152722ca7e9576b56955ca7b3da0028ba4f94f8258d'
const IMMUTABLE_START = 24

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

function prune(full: any, rootKey: string) {
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

async function ethGetTxInput(hash: string): Promise<string> {
	const r = await fetch(RPC, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({
			jsonrpc: '2.0',
			id: 1,
			method: 'eth_getTransactionByHash',
			params: [hash],
		}),
	})
	const j = (await r.json()) as { result?: { input?: string } }
	return j.result?.input || ''
}

function extractCtorArgsFromFactoryCreate(input: string, artifactBytecode: string): string {
	const raw = input.startsWith('0x') ? input.slice(2) : input
	if (!raw.startsWith('ef759095')) {
		throw new Error(`unexpected factory selector ${raw.slice(0, 8)}`)
	}
	const payload = Buffer.from(raw.slice(8), 'hex')
	const offset = Number(payload.readBigUInt64BE(96 + 24))
	const blen = Number(payload.readBigUInt64BE(offset + 24))
	const init = payload.subarray(offset + 32, offset + 32 + blen).toString('hex')
	const bc = artifactBytecode.startsWith('0x') ? artifactBytecode.slice(2).toLowerCase() : artifactBytecode.toLowerCase()
	if (!init.startsWith(bc)) {
		throw new Error('create tx initCode does not start with current BeaconProxy artifact bytecode')
	}
	return init.slice(bc.length)
}

function localDeployedBytecode(solcPath: string, prunedPath: string): string {
	if (!fs.existsSync(solcPath)) {
		throw new Error(`solc missing at ${solcPath}`)
	}
	const res = spawnSync(solcPath, ['--standard-json', prunedPath], {
		encoding: 'utf-8',
		maxBuffer: 64 * 1024 * 1024,
	})
	if (res.status !== 0) {
		throw new Error(`solc failed: ${res.stderr || res.stdout}`)
	}
	const out = JSON.parse(res.stdout)
	const obj = out?.contracts?.[SOURCE_KEY]?.BeamioUserCardBeaconProxy?.evm?.deployedBytecode?.object
	if (!obj) {
		const errs = JSON.stringify(out?.errors?.slice?.(0, 3) || out?.errors || 'no bytecode', null, 2)
		throw new Error(`no deployedBytecode for BeaconProxy\n${errs}`)
	}
	return `0x${obj}`.toLowerCase()
}

function patchBeaconImmutable(local: string, beacon: string): string {
	const body = local.startsWith('0x') ? local.slice(2) : local
	const beaconWord = beacon.replace(/^0x/, '').toLowerCase().padStart(64, '0')
	const start = IMMUTABLE_START * 2
	return `0x${body.slice(0, start)}${beaconWord}${body.slice(start + 64)}`
}

async function isVerified(addr: string): Promise<{ ok: boolean; detail: string }> {
	const r = await fetch(`${SCAN}/api/v2/smart-contracts/${addr}`)
	if (!r.ok) return { ok: false, detail: `http ${r.status}` }
	const d = (await r.json()) as {
		is_verified?: boolean
		is_partially_verified?: boolean
		source_code?: string
		name?: string
	}
	const ok = Boolean(d.is_verified || d.is_partially_verified || (d.source_code && d.source_code.length > 20))
	return {
		ok,
		detail: `verified=${d.is_verified} partial=${d.is_partially_verified} name=${d.name} srcLen=${(d.source_code || '').length}`,
	}
}

async function main() {
	const prior = await isVerified(ADDR)
	if (prior.ok) {
		console.log('Already verified:', prior.detail)
		console.log(`${SCAN}/address/${ADDR}?tab=contract`)
		return
	}

	const fullPath = path.join(root, FULL_REL)
	if (!fs.existsSync(fullPath)) throw new Error(`Missing ${FULL_REL}`)
	const full = JSON.parse(fs.readFileSync(fullPath, 'utf-8'))
	const pruned = prune(full, SOURCE_KEY)
	const prunedPath = path.join(root, PRUNED_REL)
	fs.writeFileSync(prunedPath, JSON.stringify(pruned) + '\n')
	console.log(`wrote ${PRUNED_REL} sources=${Object.keys(pruned.sources).length}`)

	const artifact = JSON.parse(
		fs.readFileSync(path.join(root, 'src/x402sdk/src/ABI/BeamioUserCardBeaconProxyArtifact.json'), 'utf-8'),
	) as { bytecode: string }
	const factoryInput = await ethGetTxInput(CREATE_TX)
	const ctorHex = extractCtorArgsFromFactoryCreate(factoryInput, artifact.bytecode)
	fs.writeFileSync(path.join(root, CTOR_REL), ctorHex + '\n')
	if (!ctorHex.toLowerCase().startsWith(BEACON.slice(2).toLowerCase().padStart(64, '0'))) {
		throw new Error(`constructor beacon mismatch: ${ctorHex.slice(0, 64)}`)
	}
	console.log(`constructor args bytes=${ctorHex.length / 2}`)

	const onchain = await ethGetCode(ADDR)
	const solcPath =
		process.env.SOLC ||
		`${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd`
	const local = localDeployedBytecode(solcPath, prunedPath)
	const patched = patchBeaconImmutable(local, BEACON)
	if (patched !== onchain) {
		console.error(`bytecode mismatch localLen=${patched.length} chainLen=${onchain.length}`)
		console.error(`localTail=${patched.slice(-24)} chainTail=${onchain.slice(-24)}`)
		console.error(`localImm=${patched.slice(2 + IMMUTABLE_START * 2, 2 + IMMUTABLE_START * 2 + 64)}`)
		console.error(`chainImm=${onchain.slice(2 + IMMUTABLE_START * 2, 2 + IMMUTABLE_START * 2 + 64)}`)
		throw new Error('local solc deployedBytecode != eth_getCode — abort submit')
	}
	console.log('local bytecode matches chain ✅')

	const form = new FormData()
	form.set('compiler_version', 'v0.8.35+commit.47b9dedd')
	form.set('contract_name', CONTRACT)
	form.set('license_type', 'mit')
	form.set('autodetect_constructor_args', 'false')
	form.set('constructor_args', ctorHex)
	form.set(
		'files[0]',
		new File([JSON.stringify(pruned)], 'BeamioUserCardBeaconProxy.json', { type: 'application/json' }),
	)

	const url = `${SCAN}/api/v2/smart-contracts/${ADDR}/verification/via/standard-input`
	const res = await fetch(url, { method: 'POST', body: form as unknown as BodyInit })
	const text = await res.text()
	console.log(`submit → HTTP ${res.status}: ${text.slice(0, 800)}`)

	const max = Number(process.env.CONET_VERIFY_POLL_MAX || 180)
	for (let i = 0; i < max; i++) {
		await new Promise((r) => setTimeout(r, 4000))
		const st = await isVerified(ADDR)
		if (st.ok) {
			console.log('\n✅ Verified:', st.detail)
			console.log(`${SCAN}/address/${ADDR}?tab=contract`)
			return
		}
		process.stdout.write('.')
	}
	throw new Error(`poll timeout ${ADDR}`)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
