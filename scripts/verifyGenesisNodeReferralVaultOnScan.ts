/**
 * Verify GenesisNodeReferralVaultV1 impl (+ optional OZ proxy) on CoNET Blockscout.
 *
 *   node scripts/exportStandardJsonFromBuildInfo.mjs GenesisNodeReferralVaultV1 --full
 *   VERIFY_CHAIN=conet npx tsx scripts/verifyGenesisNodeReferralVaultOnScan.ts
 */

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.join(__dirname, '..')
const DEPLOY = path.join(ROOT, 'deployments/conet-genesis-node-referral-vault.json')
const API = process.env.CONET_BLOCKSCOUT_API ?? 'https://mainnet.conet.network/api'
const POLL_MAX = Number(process.env.CONET_VERIFY_POLL_MAX ?? '90')

type DeployJson = {
	contracts?: {
		GenesisNodeReferralVaultV1Implementation?: string
		GenesisNodeReferralVaultV1Proxy?: string
	}
}

async function isVerified(addr: string): Promise<boolean> {
	const url = `https://mainnet.conet.network/api/v2/smart-contracts/${addr}`
	const res = await fetch(url)
	if (!res.ok) return false
	const j = (await res.json()) as {
		is_verified?: boolean
		is_partially_verified?: boolean
		source_code?: string
	}
	return Boolean(j.is_verified || j.is_partially_verified || (j.source_code && j.source_code.length > 0))
}

async function submitStandardInput(addr: string, jsonPath: string, contractName: string): Promise<void> {
	const form = new FormData()
	form.append('compiler_version', 'v0.8.35+commit.47b9dedd')
	form.append('contract_name', contractName)
	form.append('autodetect_constructor_args', 'true')
	form.append('license_type', 'mit')
	const buf = fs.readFileSync(jsonPath)
	form.append('files[0]', new Blob([buf], { type: 'application/json' }), path.basename(jsonPath))

	const url = `https://mainnet.conet.network/api/v2/smart-contracts/${addr}/verification/via/standard-input`
	const res = await fetch(url, { method: 'POST', body: form })
	const text = await res.text()
	console.log(`[submit ${addr}] HTTP ${res.status}: ${text.slice(0, 400)}`)
}

async function pollVerified(addr: string): Promise<boolean> {
	for (let i = 0; i < POLL_MAX; i++) {
		if (await isVerified(addr)) {
			console.log(`[ok] ${addr} verified`)
			return true
		}
		await new Promise((r) => setTimeout(r, 4000))
	}
	console.warn(`[timeout] ${addr} not verified after poll`)
	return false
}

async function main(): Promise<void> {
	if (!fs.existsSync(DEPLOY)) throw new Error(`Missing ${DEPLOY}`)
	const data = JSON.parse(fs.readFileSync(DEPLOY, 'utf8')) as DeployJson
	const impl = data.contracts?.GenesisNodeReferralVaultV1Implementation
	const proxy = data.contracts?.GenesisNodeReferralVaultV1Proxy
	if (!impl) throw new Error('Missing implementation address')

	const fullJson = path.join(ROOT, 'deployments/base-GenesisNodeReferralVaultV1-standard-input-FULL.json')
	if (!fs.existsSync(fullJson)) {
		console.log('Exporting FULL Standard JSON…')
		const { execSync } = await import('node:child_process')
		execSync('node scripts/exportStandardJsonFromBuildInfo.mjs GenesisNodeReferralVaultV1 --full', {
			cwd: ROOT,
			stdio: 'inherit',
		})
	}

	console.log('API hint (legacy):', API)
	if (!(await isVerified(impl))) {
		await submitStandardInput(
			impl,
			fullJson,
			'project/src/mainnet/GenesisNodeReferralVaultV1.sol:GenesisNodeReferralVaultV1',
		)
		await pollVerified(impl)
	} else {
		console.log(`[skip] impl already verified: ${impl}`)
	}

	if (proxy) {
		const ok = await isVerified(proxy)
		console.log(ok ? `[ok] proxy verified: ${proxy}` : `[note] proxy ${proxy} — verify via legacy ERC1967 if needed`)
	}
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
