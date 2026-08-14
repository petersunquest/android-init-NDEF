/**
 * Export pruned Standard JSON for 8 CoNET BeamioUserCard gateway/view libs,
 * local-match eth_getCode (solc 0.8.35), then Blockscout v2 verify.
 *
 * Source tree: deployments/conet-BeamioUserCard-0xBf837c60-verify-buildinfo.json
 *
 * Usage:
 *   npx tsx scripts/verifyBeamioUserCardGatewayLibsConet.ts
 *   CONET_VERIFY_POLL_MAX=90 npx tsx scripts/verifyBeamioUserCardGatewayLibsConet.ts
 */
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { spawnSync } from 'child_process'
import { FormData, File } from 'undici'
import { ethers } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.join(__dirname, '..')
const SCAN = 'https://mainnet.conet.network'
const RPC = 'https://publicrpc.conet.network'
const COMPILER = 'v0.8.35+commit.47b9dedd'
const SOLC =
	process.env.SOLC_PATH ||
	path.join(
		process.env.HOME || '',
		'Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd',
	)
const FULL_REL = 'deployments/conet-BeamioUserCard-0xBf837c60-verify-buildinfo.json'

type StdJson = {
	language: string
	sources: Record<string, { content: string }>
	settings: Record<string, unknown> & {
		libraries?: Record<string, Record<string, string>>
		outputSelection?: unknown
	}
}

const TARGETS: {
	name: string
	sourceKey: string
	address: string
	linkedLibraries?: Record<string, Record<string, string>>
}[] = [
	{
		name: 'BeamioUserCardAdminGatewayLib',
		sourceKey: 'project/src/BeamioUserCard/BeamioUserCardAdminGatewayLib.sol',
		address: '0x602646B80Df4d46eF3dCF1C2AB60899135e5d0AC',
	},
	{
		name: 'BeamioUserCardFaucetGatewayLib',
		sourceKey: 'project/src/BeamioUserCard/BeamioUserCardFaucetGatewayLib.sol',
		address: '0xE8BCc970e1C51d0F8fFDcB3beCe1DEAd4B786986',
	},
	{
		name: 'BeamioUserCardGatewayMintLib',
		sourceKey: 'project/src/BeamioUserCard/BeamioUserCardGatewayMintLib.sol',
		address: '0x4d62ab34c4E7df4a124806A45F82C591681E7C4D',
	},
	{
		name: 'BeamioUserCardGovernanceLib',
		sourceKey: 'project/src/BeamioUserCard/BeamioUserCardGovernanceLib.sol',
		address: '0x1656673561FfB970902D4e7Ec734Fcb3D5b2d286',
	},
	{
		name: 'BeamioUserCardIssuedNftGatewayLib',
		sourceKey: 'project/src/BeamioUserCard/BeamioUserCardIssuedNftGatewayLib.sol',
		address: '0x2dCe8094277BD85A0f1bcd7f72ce86C56309879d',
	},
	{
		name: 'BeamioUserCardModuleRouterLib',
		sourceKey: 'project/src/BeamioUserCard/BeamioUserCardModuleRouterLib.sol',
		address: '0x6c1d2b58f0893F35Cf608b734CB425A44bf139F5',
	},
	{
		name: 'BeamioUserCardViewsLib',
		sourceKey: 'project/src/BeamioUserCard/BeamioUserCardViewsLib.sol',
		address: '0x1c7c122429Da18e6078d9CEbb7B5b30F0Aa2a033',
	},
	{
		name: 'BeamioUserCardRedeemGatewayLib',
		sourceKey: 'project/src/BeamioUserCard/BeamioUserCardRedeemGatewayLib.sol',
		address: '0x10dAdE725b8E12d67AEdBaf2a50C57E1B86F5f82',
		linkedLibraries: {
			'project/src/BeamioUserCard/BeamioUserCardIssuedNftGatewayLib.sol': {
				BeamioUserCardIssuedNftGatewayLib: '0x2dCe8094277BD85A0f1bcd7f72ce86C56309879d',
			},
			'project/src/BeamioUserCard/BeamioUserCardTransferLib.sol': {
				BeamioUserCardTransferLib: '0xBcf3f8C5994B02B89fB743e1dee6AFDD5a49a664',
			},
		},
	},
]

const IMPORT_RE =
	/^\s*import\s+(?:\{[^}]*\}\s+from\s+)?["']([^"']+)["']\s*;/gm

function resolveImport(full: StdJson, fromKey: string, imp: string): string | null {
	if (imp.startsWith('@') || imp.startsWith('hardhat')) {
		if (full.sources[imp]) return imp
		const prefixed = imp.startsWith('project/') ? imp : `project/${imp}`
		if (full.sources[prefixed]) return prefixed
		for (const k of Object.keys(full.sources)) {
			if (k.endsWith(`/${imp}`) || k.endsWith(imp)) return k
		}
		return null
	}
	const base = fromKey.split('/').slice(0, -1)
	const parts = [...base, ...imp.split('/')]
	const out: string[] = []
	for (const p of parts) {
		if (p === '..') out.pop()
		else if (p !== '.') out.push(p)
	}
	const key = out.join('/')
	return full.sources[key] ? key : null
}

function prune(full: StdJson, rootKey: string, linkedLibraries?: StdJson['settings']['libraries']): StdJson {
	const keep = new Set<string>()
	const stack = [rootKey]
	while (stack.length) {
		const k = stack.pop()!
		if (keep.has(k)) continue
		if (!full.sources[k]) throw new Error(`missing source ${k}`)
		keep.add(k)
		const src = full.sources[k].content || ''
		IMPORT_RE.lastIndex = 0
		let m: RegExpExecArray | null
		while ((m = IMPORT_RE.exec(src))) {
			const r = resolveImport(full, k, m[1])
			if (!r) throw new Error(`unresolved import ${m[1]} from ${k}`)
			if (!keep.has(r)) stack.push(r)
		}
	}
	const settings = structuredClone(full.settings)
	settings.libraries = linkedLibraries || {}
	settings.outputSelection = {
		'*': {
			'': ['ast'],
			'*': ['abi', 'evm.bytecode', 'evm.deployedBytecode', 'evm.methodIdentifiers', 'metadata'],
		},
	}
	delete (settings as { compilationTarget?: unknown }).compilationTarget
	return {
		language: full.language || 'Solidity',
		sources: Object.fromEntries([...keep].map((k) => [k, full.sources[k]])),
		settings,
	}
}

type DeployedOut = {
	object: string
	immutableReferences?: Record<string, { start: number; length: number }[]>
	linkReferences?: unknown
}

function compileDeployed(jsonPath: string, sourceKey: string, contractName: string): DeployedOut {
	if (!fs.existsSync(SOLC)) throw new Error(`solc not found: ${SOLC}`)
	const r = spawnSync(SOLC, ['--standard-json', jsonPath], {
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024,
	})
	if (r.error) throw r.error
	const out = JSON.parse(r.stdout || '{}') as {
		errors?: { severity: string; message: string }[]
		contracts?: Record<string, Record<string, { evm: { deployedBytecode: DeployedOut } }>>
	}
	const errs = (out.errors || []).filter((e) => e.severity === 'error')
	if (errs.length) throw new Error(`${contractName} compile: ${errs[0].message}`)
	const obj = out.contracts?.[sourceKey]?.[contractName]?.evm?.deployedBytecode
	if (!obj?.object) throw new Error(`${contractName}: no deployedBytecode`)
	const linkRefs = obj.linkReferences as
		| Record<string, Record<string, { start: number; length: number }[]>>
		| undefined
	if (linkRefs && Object.keys(linkRefs).length) {
		throw new Error(
			`${contractName}: unresolved linkReferences after settings.libraries — ${JSON.stringify(linkRefs)}`,
		)
	}
	return {
		object: obj.object.toLowerCase().replace(/^0x/, ''),
		immutableReferences: obj.immutableReferences,
	}
}

/** Solidity libraries embed their own deploy address (library_deploy_address immutable). */
function patchLibraryDeployAddress(localHex: string, libraryAddress: string, immutableReferences?: DeployedOut['immutableReferences']): string {
	const addr = libraryAddress.replace(/^0x/i, '').toLowerCase()
	if (addr.length !== 40) throw new Error(`bad library address ${libraryAddress}`)
	let out = localHex
	const slots = immutableReferences?.library_deploy_address || []
	if (slots.length) {
		for (const { start, length } of slots) {
			// solc reports 32-byte slot; address occupies the last 20 bytes
			const addrStart = start + (length >= 32 ? 12 : 0)
			const off = addrStart * 2
			out = out.slice(0, off) + addr + out.slice(off + 40)
		}
		return out
	}
	// fallback: replace first 20-byte zero run that matches chain pattern at known offsets
	return out
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
		detail: `name=${d.name} verified=${d.is_verified} partial=${d.is_partially_verified} srcLen=${(d.source_code || '').length}`,
	}
}

async function submitVerify(addr: string, contractFq: string, json: string): Promise<void> {
	const form = new FormData()
	form.set('compiler_version', COMPILER)
	form.set('contract_name', contractFq)
	form.set('license_type', 'mit')
	form.set('autodetect_constructor_args', 'true')
	form.set('files[0]', new File([json], 'standard-input.json', { type: 'application/json' }))
	const url = `${SCAN}/api/v2/smart-contracts/${addr}/verification/via/standard-input`
	const res = await fetch(url, { method: 'POST', body: form as unknown as BodyInit })
	const text = await res.text()
	console.log(`  submit → HTTP ${res.status}: ${text.slice(0, 240)}`)
	if (!res.ok && !/already|verified|started/i.test(text)) {
		throw new Error(`submit failed ${addr}: ${text.slice(0, 400)}`)
	}
}

async function pollVerified(addr: string): Promise<void> {
	const max = Number(process.env.CONET_VERIFY_POLL_MAX || 90)
	for (let i = 0; i < max; i++) {
		await new Promise((r) => setTimeout(r, 4000))
		const st = await isVerified(addr)
		if (st.ok) {
			console.log(`  ✅ ${st.detail}`)
			return
		}
		process.stdout.write('.')
	}
	throw new Error(`poll timeout ${addr}`)
}

async function main() {
	const fullPath = path.join(root, FULL_REL)
	if (!fs.existsSync(fullPath)) throw new Error(`Missing ${FULL_REL}`)
	const full = JSON.parse(fs.readFileSync(fullPath, 'utf8')) as StdJson
	const provider = new ethers.JsonRpcProvider(RPC)

	const results: { name: string; address: string; status: string }[] = []

	for (const t of TARGETS) {
		console.log(`\n=== ${t.name} @ ${t.address} ===`)
		const prior = await isVerified(t.address)
		if (prior.ok) {
			console.log('  already verified:', prior.detail)
			results.push({ name: t.name, address: t.address, status: 'already' })
			continue
		}

		const pruned = prune(full, t.sourceKey, t.linkedLibraries)
		const outRel = `deployments/conet-${t.name}-verify-buildinfo.json`
		const outPath = path.join(root, outRel)
		const jsonText = JSON.stringify(pruned)
		fs.writeFileSync(outPath, jsonText)
		console.log(`  wrote ${outRel} (${Object.keys(pruned.sources).length} sources)`)

		const compiled = compileDeployed(outPath, t.sourceKey, t.name)
		const local = patchLibraryDeployAddress(compiled.object, t.address, compiled.immutableReferences)
		const chain = (await provider.getCode(t.address)).replace(/^0x/i, '').toLowerCase()
		if (!chain || chain === '0x') throw new Error(`no code at ${t.address}`)
		if (local !== chain) {
			console.error(`  ❌ bytecode mismatch local=${local.length / 2} chain=${chain.length / 2}`)
			results.push({ name: t.name, address: t.address, status: 'bytecode_mismatch' })
			continue
		}
		console.log(`  local bytecode match (${local.length / 2} bytes)`)

		const fq = `${t.sourceKey}:${t.name}`
		// Blockscout v2 often accepts short library names more reliably than FQ paths.
		await submitVerify(t.address, t.name, jsonText)
		await pollVerified(t.address)
		console.log(`  ${SCAN}/address/${t.address}?tab=contract`)
		results.push({ name: t.name, address: t.address, status: 'verified' })
	}

	console.log('\n=== Summary ===')
	for (const r of results) console.log(`${r.status.padEnd(18)} ${r.name} ${r.address}`)
	const bad = results.filter((r) => r.status === 'bytecode_mismatch')
	if (bad.length) process.exit(1)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
