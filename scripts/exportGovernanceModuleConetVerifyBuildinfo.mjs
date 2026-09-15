import fs from 'node:fs'
import path from 'node:path'

const root = process.cwd()
const sourceKey = 'project/src/BeamioUserCard/GovernanceModule.sol'
const buildInfoDir = path.join(root, 'artifacts/build-info')
const sourceOnDisk = fs.readFileSync(path.join(root, sourceKey.slice('project/'.length)), 'utf8')
const files = fs.readdirSync(buildInfoDir).filter((file) => file.endsWith('.json'))

let selected
for (const file of files) {
	const candidate = JSON.parse(fs.readFileSync(path.join(buildInfoDir, file), 'utf8'))
	const content = candidate?.input?.sources?.[sourceKey]?.content
	if (content === sourceOnDisk) {
		selected = candidate.input
		break
	}
}
if (!selected) throw new Error('No build-info matching current GovernanceModule source')

const imports = /^\s*import\s+(?:[^'"]+from\s+)?["']([^"']+)["'];/gm
const kept = new Set()
const queue = [sourceKey]
while (queue.length) {
	const key = queue.shift()
	if (kept.has(key)) continue
	const source = selected.sources[key]
	if (!source) throw new Error(`Missing recursive dependency ${key}`)
	kept.add(key)
	for (const match of source.content.matchAll(imports)) {
		const imp = match[1]
		const base = path.dirname(key.slice('project/'.length))
		const resolved = imp.startsWith('.') ? path.posix.normalize(path.posix.join(base, imp)) : imp
		const next = `project/${resolved}`
		if (selected.sources[next]) queue.push(next)
	}
}

const settings = { ...selected.settings }
delete settings.compilationTarget
settings.outputSelection = {
	'*': {
		'': ['ast'],
		'*': ['abi', 'evm.bytecode', 'evm.deployedBytecode', 'evm.methodIdentifiers', 'metadata'],
	},
}
const output = {
	language: selected.language,
	sources: Object.fromEntries([...kept].map((key) => [key, selected.sources[key]])),
	settings,
}
const out = path.join(root, 'deployments/conet-GovernanceModule-standard-input-FULL-FORM.json')
fs.writeFileSync(out, JSON.stringify(output, null, 2) + '\n')
console.log(`Wrote ${out} (${kept.size} sources, ${fs.statSync(out).size} bytes)`)
