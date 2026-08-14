/**
 * Verify merchant BeamioUserCard 0xBf837c60…9b45 (CINE AI) on CoNET Blockscout.
 *
 * Prereq: deployments/conet-BeamioUserCard-0xBf837c60-verify-buildinfo.json
 * (pruned Standard JSON; local solc 0.8.35 deployedBytecode matches eth_getCode after immutable patch)
 *
 * Usage:
 *   npx tsx scripts/verifyBeamioUserCard0xBf837c60Conet.ts
 */
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { FormData, File } from 'undici'
import { AbiCoder } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.join(__dirname, '..')
const SCAN = 'https://mainnet.conet.network'
const ADDR = '0xBf837c60E59DB05Ca26561be025753d5E60e9b45'
const COMPILER = 'v0.8.35+commit.47b9dedd'
const CONTRACT = 'project/src/BeamioUserCard/BeamioUserCard.sol:BeamioUserCard'
const JSON_REL = 'deployments/conet-BeamioUserCard-0xBf837c60-verify-buildinfo.json'

async function isVerified(addr: string): Promise<{ ok: boolean; detail: string }> {
	const r = await fetch(`${SCAN}/api/v2/smart-contracts/${addr}`)
	if (!r.ok) return { ok: false, detail: `http ${r.status}` }
	const d = (await r.json()) as {
		is_verified?: boolean
		is_partially_verified?: boolean
		source_code?: string
	}
	const ok = Boolean(d.is_verified || d.is_partially_verified || (d.source_code && d.source_code.length > 20))
	return {
		ok,
		detail: `verified=${d.is_verified} partial=${d.is_partially_verified} srcLen=${(d.source_code || '').length}`,
	}
}

async function main() {
	const prior = await isVerified(ADDR)
	if (prior.ok) {
		console.log('Already verified:', prior.detail)
		console.log(`${SCAN}/address/${ADDR}?tab=contract`)
		return
	}

	const jsonPath = path.join(root, JSON_REL)
	if (!fs.existsSync(jsonPath)) throw new Error(`Missing ${JSON_REL}`)
	const json = fs.readFileSync(jsonPath, 'utf-8')

	const ctorHex = AbiCoder.defaultAbiCoder()
		.encode(
			['string', 'uint8', 'uint256', 'address', 'address', 'uint8', 'bool', 'string'],
			[
				'https://beamio.app/api/metadata/0x',
				0,
				1_000_000n,
				'0x60002418Fe90AaA30d5F0DA44C3d338b5b6266ee',
				'0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB',
				0,
				false,
				'CINE AI',
			],
		)
		.slice(2)

	const form = new FormData()
	form.set('compiler_version', COMPILER)
	form.set('contract_name', CONTRACT)
	form.set('license_type', 'mit')
	form.set('autodetect_constructor_args', 'false')
	form.set('constructor_args', ctorHex)
	form.set('files[0]', new File([json], 'BeamioUserCard.json', { type: 'application/json' }))

	const url = `${SCAN}/api/v2/smart-contracts/${ADDR}/verification/via/standard-input`
	const res = await fetch(url, { method: 'POST', body: form as unknown as BodyInit })
	const text = await res.text()
	console.log(`submit → HTTP ${res.status}: ${text.slice(0, 500)}`)

	const max = Number(process.env.CONET_VERIFY_POLL_MAX || 120)
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
