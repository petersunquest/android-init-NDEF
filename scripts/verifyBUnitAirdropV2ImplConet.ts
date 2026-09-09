/**
 * Prune + local bytecode precheck + Blockscout v2 verify for BUnitAirdropV2 implementation.
 *
 *   BUNIT_AIRDROP_V2_IMPL=0x… CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyBUnitAirdropV2ImplConet.ts
 *
 * Falls back to deployments/conet-BUnitAirdropV2-usedUsdcPurchaseHash.json or
 * deployments/conet-ReferralPurchaseSplitV1.json airdropImplementation.
 */

import { execSync } from 'child_process'
import * as fs from 'fs'
import * as path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.join(__dirname, '..')
const SCAN = 'https://mainnet.conet.network'
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const SOLC_035 = path.join(
	process.env.HOME || '',
	'Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd',
)

const EXPORT_KEY = 'BUnitAirdropV2'
const SOURCE_KEY = 'project/src/b-unit/BUnitAirdropV2.sol'
const CONTRACT_NAME = 'BUnitAirdropV2'
const FQ_NAME = 'project/src/b-unit/BUnitAirdropV2.sol:BUnitAirdropV2'

function applyRemappings(spec: string, remappings: string[]): string {
	let best: { from: string; to: string } | null = null
	for (const raw of remappings) {
		const eq = raw.indexOf('=')
		if (eq < 0) continue
		const from = raw.slice(0, eq)
		const to = raw.slice(eq + 1)
		const colon = from.lastIndexOf(':')
		const prefix = colon >= 0 ? from.slice(colon + 1) : from
		if (spec.startsWith(prefix) && (!best || prefix.length > best.from.length)) {
			best = { from: prefix, to }
		}
	}
	if (!best) return spec
	return best.to + spec.slice(best.from.length)
}

function resolveImport(
	fromKey: string,
	spec: string,
	sources: Record<string, unknown>,
	remappings: string[],
): string | null {
	const candidates = new Set<string>([spec, applyRemappings(spec, remappings)])
	if (spec.startsWith('./') || spec.startsWith('../')) {
		const fromDir = path.posix.dirname(fromKey.replace(/^project\//, ''))
		const joined = path.posix.normalize(path.posix.join(fromDir, spec))
		candidates.add(`project/${joined}`)
		candidates.add(joined)
	}
	for (const c of candidates) {
		if (sources[c]) return c
	}
	return null
}

function normalizeNpmSourceKeys(input: {
	language: string
	sources: Record<string, { content: string }>
	settings: Record<string, unknown>
}) {
	const remapped: Record<string, { content: string }> = {}
	for (const [key, val] of Object.entries(input.sources)) {
		let next = key
		const mUp = key.match(/^npm\/@openzeppelin\/contracts-upgradeable@[^/]+\/(.+)$/)
		const mBase = key.match(/^npm\/@openzeppelin\/contracts@[^/]+\/(.+)$/)
		if (mUp) next = `@openzeppelin/contracts-upgradeable/${mUp[1]}`
		else if (mBase) next = `@openzeppelin/contracts/${mBase[1]}`
		remapped[next] = val
	}
	const settings = { ...input.settings }
	delete settings.compilationTarget
	settings.remappings = []
	settings.outputSelection = {
		'*': {
			'': ['ast'],
			'*': ['abi', 'evm.bytecode', 'evm.deployedBytecode', 'evm.methodIdentifiers', 'metadata'],
		},
	}
	return { language: input.language, sources: remapped, settings }
}

function prune(
	full: { language: string; sources: Record<string, { content: string }>; settings: Record<string, unknown> },
	rootKey: string,
) {
	const sources = full.sources
	const remappings: string[] = Array.isArray(full.settings?.remappings)
		? (full.settings.remappings as string[])
		: []
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
	return normalizeNpmSourceKeys({
		language: full.language,
		sources: prunedSources,
		settings: { ...full.settings },
	})
}

async function checkVerified(addr: string): Promise<{ verified: boolean; partial: boolean; len: number }> {
	const res = await fetch(`${SCAN}/api/v2/smart-contracts/${addr}`)
	if (!res.ok) return { verified: false, partial: false, len: 0 }
	const d = (await res.json()) as {
		is_verified?: boolean
		is_partially_verified?: boolean
		source_code?: string
	}
	return {
		verified: Boolean(d.is_verified),
		partial: Boolean(d.is_partially_verified),
		len: (d.source_code || '').length,
	}
}

async function ethGetCode(addr: string): Promise<string> {
	const codeRes = await fetch(RPC, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_getCode', params: [addr, 'latest'] }),
	})
	const codeJson = (await codeRes.json()) as { result?: string }
	return (codeJson.result || '0x').toLowerCase()
}

function compilerFromCode(code: string): string {
	const tail = code.slice(-24)
	if (tail.includes('000821')) return 'v0.8.33+commit.64118f21'
	if (tail.includes('00081b')) return 'v0.8.27+commit.40f2ac0b'
	return 'v0.8.35+commit.47b9dedd'
}

function extractDeployedBytecode(
	out: {
		contracts?: Record<string, Record<string, { evm?: { deployedBytecode?: { object?: string } } }>>
		errors?: unknown
	},
	sourceKey: string,
	contractName: string,
): string {
	const obj =
		out?.contracts?.[sourceKey]?.[contractName]?.evm?.deployedBytecode?.object ||
		out?.contracts?.[sourceKey.replace(/^project\//, '')]?.[contractName]?.evm?.deployedBytecode?.object
	return String(obj || '').replace(/^0x/i, '').toLowerCase()
}

function localBytecodeMatch(
	prunedPath: string,
	sourceKey: string,
	contractName: string,
	onchainCode: string,
	addr: string,
): boolean {
	if (!fs.existsSync(SOLC_035)) {
		console.log('skip local bytecode precheck (solc 0.8.35 not in hardhat cache)')
		return true
	}
	const outPath = `/tmp/verify-${contractName}.json`
	execSync(`"${SOLC_035}" --standard-json "${prunedPath}" > "${outPath}"`, { shell: true })
	const out = JSON.parse(fs.readFileSync(outPath, 'utf-8'))
	const local = extractDeployedBytecode(out, sourceKey, contractName)
	if (!local) {
		console.log('local compile missing deployedBytecode; errors:', JSON.stringify(out.errors || []).slice(0, 800))
		return false
	}
	const onchain = onchainCode.replace(/^0x/i, '').toLowerCase()
	if (onchain === local) {
		console.log(`local bytecode match ${contractName}: exact (len=${local.length})`)
		return true
	}
	if (onchain.length !== local.length) {
		console.log(`local bytecode length mismatch ${contractName} local=${local.length} onchain=${onchain.length}`)
		return false
	}
	const addrNo0x = addr.replace(/^0x/i, '').toLowerCase()
	let immutableNibbles = 0
	let otherDiffs = 0
	for (let i = 0; i < local.length; i++) {
		if (local[i] === onchain[i]) continue
		if (local.slice(i, i + 40) === '0'.repeat(40) && onchain.slice(i, i + 40) === addrNo0x) {
			immutableNibbles += 40
			i += 39
			continue
		}
		otherDiffs++
	}
	console.log(
		`local bytecode ${contractName}: immutable-slot diffs≈${immutableNibbles / 2}B otherNibbleDiffs=${otherDiffs}`,
	)
	return otherDiffs === 0
}

async function submitStandardInput(
	addr: string,
	jsonPath: string,
	contractName: string,
	compilerVersion: string,
): Promise<void> {
	const form = new FormData()
	form.append('compiler_version', compilerVersion)
	form.append('contract_name', contractName)
	form.append('autodetect_constructor_args', 'true')
	form.append('license_type', 'mit')
	const blob = new Blob([fs.readFileSync(jsonPath)], { type: 'application/json' })
	form.append('files[0]', blob, path.basename(jsonPath))
	const url = `${SCAN}/api/v2/smart-contracts/${addr}/verification/via/standard-input`
	const res = await fetch(url, { method: 'POST', body: form })
	const text = await res.text()
	console.log('submit', addr, res.status, text.slice(0, 400))
}

async function poll(addr: string, label: string): Promise<boolean> {
	const pollMax = Number(process.env.CONET_VERIFY_POLL_MAX || '90')
	for (let i = 0; i < pollMax; i++) {
		await new Promise((r) => setTimeout(r, 4000))
		const st = await checkVerified(addr)
		console.log(`poll ${label} #${i + 1}`, st)
		if (st.verified || st.partial) return true
	}
	return false
}

function resolveImplAddr(): string {
	const fromEnv = (process.env.BUNIT_AIRDROP_V2_IMPL || '').trim()
	if (/^0x[0-9a-fA-F]{40}$/.test(fromEnv)) return fromEnv

	const usedHashPath = path.join(ROOT, 'deployments/conet-BUnitAirdropV2-usedUsdcPurchaseHash.json')
	if (fs.existsSync(usedHashPath)) {
		const j = JSON.parse(fs.readFileSync(usedHashPath, 'utf-8')) as { implementation?: string }
		if (j.implementation && /^0x[0-9a-fA-F]{40}$/.test(j.implementation)) return j.implementation
	}

	const splitPath = path.join(ROOT, 'deployments/conet-ReferralPurchaseSplitV1.json')
	if (fs.existsSync(splitPath)) {
		const j = JSON.parse(fs.readFileSync(splitPath, 'utf-8')) as { airdropImplementation?: string }
		if (j.airdropImplementation && /^0x[0-9a-fA-F]{40}$/.test(j.airdropImplementation)) {
			return j.airdropImplementation
		}
	}

	throw new Error('Set BUNIT_AIRDROP_V2_IMPL or deploy snapshot with implementation address')
}

async function main() {
	const addr = resolveImplAddr()
	console.log('airdropImpl', addr)

	const st0 = await checkVerified(addr)
	if (st0.verified || st0.partial) {
		console.log('✅ airdropImpl already verified', addr, st0)
		return
	}

	const onchain = await ethGetCode(addr)
	if (!onchain || onchain === '0x') throw new Error(`no code at ${addr}`)
	const compiler = compilerFromCode(onchain)
	console.log('tail', onchain.slice(-24), compiler)

	execSync(`node scripts/exportStandardJsonFromBuildInfo.mjs ${EXPORT_KEY} --full`, {
		cwd: ROOT,
		stdio: 'inherit',
	})
	const fullPath = path.join(ROOT, 'deployments', `base-${EXPORT_KEY}-standard-input-FULL.json`)
	const full = JSON.parse(fs.readFileSync(fullPath, 'utf-8'))
	const pruned = prune(full, SOURCE_KEY)
	const prunedPath = path.join(ROOT, 'deployments', `conet-${EXPORT_KEY}-verify-buildinfo.json`)
	fs.writeFileSync(prunedPath, JSON.stringify(pruned) + '\n')
	console.log(`pruned sources=${Object.keys(pruned.sources).length} → ${prunedPath}`)

	if (!localBytecodeMatch(prunedPath, SOURCE_KEY, CONTRACT_NAME, onchain, addr)) {
		throw new Error('local deployedBytecode != eth_getCode; abort Blockscout submit')
	}

	await submitStandardInput(addr, prunedPath, FQ_NAME, compiler)
	const ok = await poll(addr, 'airdropImpl')
	const st = await checkVerified(addr)
	if (!ok) throw new Error(`airdropImpl verification poll timeout: ${JSON.stringify(st)}`)
	console.log('✅ airdropImpl', st)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
