import fs from 'node:fs'
import path from 'node:path'

const root = process.cwd()
const sourceKey = 'project/src/BeamioUserCard/AdminStatsQueryModuleV6.sol'
const buildInfoDir = path.join(root, 'artifacts/build-info')
const current = fs.readFileSync(path.join(root, sourceKey.slice('project/'.length)), 'utf8')
let input
for (const file of fs.readdirSync(buildInfoDir).filter((f) => f.endsWith('.json'))) {
	const build = JSON.parse(fs.readFileSync(path.join(buildInfoDir, file), 'utf8'))
	if (build?.input?.sources?.[sourceKey]?.content === current) {
		input = build.input
		break
	}
}
if (!input) throw new Error('No build-info matching current AdminStatsQueryModuleV6 source')
const imports = /^\s*import\s+(?:[^'"]+from\s+)?["']([^"']+)["'];/gm
const kept = new Set()
const queue = [sourceKey]
while (queue.length) {
	const key = queue.shift()
	if (kept.has(key)) continue
	if (!input.sources[key]) throw new Error(`Missing dependency ${key}`)
	kept.add(key)
	const base = path.dirname(key.slice('project/'.length))
	for (const match of input.sources[key].content.matchAll(imports)) {
		const resolved = match[1].startsWith('.') ? path.posix.normalize(path.posix.join(base, match[1])) : match[1]
		const next = `project/${resolved}`
		if (input.sources[next]) queue.push(next)
	}
}
const settings = { ...input.settings }
delete settings.compilationTarget
settings.outputSelection = {
	'*': {
		'': ['ast'],
		'*': ['abi', 'evm.bytecode', 'evm.deployedBytecode', 'evm.methodIdentifiers', 'metadata'],
	},
}
const out = path.join(root, 'deployments/conet-AdminStatsQueryModuleV6-standard-input-FULL-FORM.json')
fs.writeFileSync(out, JSON.stringify({
	language: input.language,
	sources: Object.fromEntries([...kept].map((key) => [key, input.sources[key]])),
	settings,
}, null, 2) + '\n')
console.log(`Wrote ${out} (${kept.size} sources, ${fs.statSync(out).size} bytes)`)
