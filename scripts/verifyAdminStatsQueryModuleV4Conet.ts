/**
 * Prune + submit AdminStatsQueryModuleV4 to CoNET Blockscout v2 standard-input.
 * Prereq: node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV4 --full
 */
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { FormData, File } from 'undici'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SCAN = 'https://mainnet.conet.network'
const COMPILER = 'v0.8.33+commit.64118f21'
const ADDR = '0x5503d4262Aa1e12bbB7049941333026CF430c24F'
const SOURCE_KEY = 'project/src/BeamioUserCard/AdminStatsQueryModuleV4.sol'
const CONTRACT_NAME =
	'project/src/BeamioUserCard/AdminStatsQueryModuleV4.sol:BeamioUserCardAdminStatsQueryModuleV4'

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

async function main() {
	if (await isVerified(ADDR)) {
		console.log(`already verified ${ADDR}`)
		return
	}
	const fullPath = path.join(
		__dirname,
		'..',
		'deployments',
		'base-AdminStatsQueryModuleV4-standard-input-FULL.json',
	)
	const full = JSON.parse(fs.readFileSync(fullPath, 'utf-8'))
	const pruned = prune(full, SOURCE_KEY)
	const outPath = path.join(__dirname, '..', 'deployments', 'conet-AdminStatsQueryModuleV4-verify-buildinfo.json')
	fs.writeFileSync(outPath, JSON.stringify(pruned) + '\n')
	console.log(`wrote ${outPath} sources=${Object.keys(pruned.sources).length}`)

	const form = new FormData()
	form.set('compiler_version', COMPILER)
	form.set('contract_name', CONTRACT_NAME)
	form.set('autodetect_constructor_args', 'true')
	form.set('license_type', 'mit')
	form.set(
		'files[0]',
		new File([JSON.stringify(pruned)], 'AdminStatsQueryModuleV4.json', { type: 'application/json' }),
	)
	const url = `${SCAN}/api/v2/smart-contracts/${ADDR}/verification/via/standard-input`
	const res = await fetch(url, { method: 'POST', body: form as any })
	const text = await res.text()
	console.log(`submit → HTTP ${res.status}: ${text.slice(0, 400)}`)
	for (let i = 0; i < 90; i++) {
		await new Promise((r) => setTimeout(r, 4000))
		if (await isVerified(ADDR)) {
			console.log(`verified ${ADDR}`)
			return
		}
		process.stdout.write('.')
	}
	console.log(`\npoll timeout ${ADDR}`)
	process.exit(1)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
