import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { FormData, File } from 'undici'

const ROOT = process.cwd()
const SCAN = process.env.CONET_BLOCKSCOUT_URL || 'https://mainnet.conet.network'
const RPC = process.env.CONET_RPC_URL || 'https://publicrpc.conet.network'
const COMPILER = process.env.CONET_SOLC_VERSION || 'v0.8.35+commit.47b9dedd'
const SOLC =
	process.env.SOLC ||
	`${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd`
const SOURCE_KEY = 'project/src/BeamioUserCard/GovernanceModule.sol'
const CONTRACT_SYMBOL = 'BeamioUserCardGovernanceModuleV1'
const CONTRACT_NAME = `${SOURCE_KEY}:${CONTRACT_SYMBOL}`
const SNAPSHOT_PATH = path.join(
	ROOT,
	'deployments/conet-GovernanceOnlyGatewayFix.json',
)
const INPUT_PATH = path.join(
	ROOT,
	'deployments/conet-GovernanceModule-standard-input-FULL-FORM.json',
)

type VerificationStatus = {
	ok: boolean
	isVerified?: boolean
	isPartiallyVerified?: boolean
}

async function rpc(method: string, params: unknown[]): Promise<any> {
	const response = await fetch(RPC, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
	})
	if (!response.ok) throw new Error(`RPC HTTP ${response.status}`)
	const body = (await response.json()) as { result?: unknown; error?: unknown }
	if (body.error) throw new Error(`RPC ${method} failed: ${JSON.stringify(body.error)}`)
	return body.result
}

async function verificationStatus(address: string): Promise<VerificationStatus> {
	const response = await fetch(`${SCAN}/api/v2/smart-contracts/${address}`)
	if (!response.ok) return { ok: false }
	const body = (await response.json()) as {
		is_verified?: boolean
		is_partially_verified?: boolean
	}
	return {
		ok: Boolean(body.is_verified || body.is_partially_verified),
		isVerified: body.is_verified,
		isPartiallyVerified: body.is_partially_verified,
	}
}

function compileLocally(input: string): string {
	if (!fs.existsSync(SOLC)) throw new Error(`Missing solc: ${SOLC}`)
	const result = spawnSync(SOLC, ['--standard-json'], {
		input,
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024,
	})
	if (result.status !== 0) {
		throw new Error(`solc failed: ${result.stderr || result.stdout}`)
	}
	const output = JSON.parse(result.stdout) as any
	const errors = (output.errors ?? []).filter(
		(item: { severity?: string }) => item.severity === 'error',
	)
	if (errors.length) throw new Error(`solc errors: ${JSON.stringify(errors, null, 2)}`)
	const bytecode =
		output.contracts?.[SOURCE_KEY]?.[CONTRACT_SYMBOL]?.evm?.deployedBytecode?.object
	if (!bytecode) throw new Error('Local solc produced no Governance deployedBytecode')
	return `0x${bytecode}`.toLowerCase()
}

async function main(): Promise<void> {
	if (!fs.existsSync(SNAPSHOT_PATH)) {
		throw new Error(`Missing ${SNAPSHOT_PATH}`)
	}
	if (!fs.existsSync(INPUT_PATH)) {
		throw new Error(
			`Missing ${INPUT_PATH}; run exportStandardJsonFromBuildInfo and exportGovernanceModuleConetVerifyBuildinfo first`,
		)
	}
	const snapshot = JSON.parse(fs.readFileSync(SNAPSHOT_PATH, 'utf8')) as {
		governanceModule: string
	}
	const address = snapshot.governanceModule
	const input = fs.readFileSync(INPUT_PATH, 'utf8')
	const localCode = compileLocally(input)
	const chainCode = String(await rpc('eth_getCode', [address, 'latest'])).toLowerCase()
	if (chainCode === '0x') throw new Error(`No code at ${address}`)
	if (localCode !== chainCode) {
		throw new Error(
			`Local deployedBytecode != eth_getCode (local=${localCode.length}, chain=${chainCode.length})`,
		)
	}
	console.log(`Local bytecode matches chain; tail=${chainCode.slice(-24)}`)

	let status = await verificationStatus(address)
	if (!status.ok) {
		const form = new FormData()
		form.set('compiler_version', COMPILER)
		form.set('contract_name', CONTRACT_NAME)
		form.set('autodetect_constructor_args', 'true')
		form.set('license_type', 'mit')
		form.set(
			'files[0]',
			new File([input], 'GovernanceModule.json', {
				type: 'application/json',
			}),
		)
		const response = await fetch(
			`${SCAN}/api/v2/smart-contracts/${address}/verification/via/standard-input`,
			{ method: 'POST', body: form as any },
		)
		const text = await response.text()
		console.log(`Submit HTTP ${response.status}: ${text.slice(0, 400)}`)
		if (!response.ok) throw new Error(`Blockscout submit failed: HTTP ${response.status}`)

		const max = Number(process.env.CONET_VERIFY_POLL_MAX || 180)
		for (let i = 0; i < max; i++) {
			await new Promise((resolve) => setTimeout(resolve, 4000))
			status = await verificationStatus(address)
			if (status.ok) break
			process.stdout.write('.')
		}
	}
	if (!status.ok) throw new Error(`Blockscout verification timed out for ${address}`)
	console.log(
		`Verified ${address} (full=${status.isVerified}, partial=${status.isPartiallyVerified})`,
	)
	console.log(`${SCAN}/address/${address}?tab=contract`)
}

main().catch((error) => {
	console.error(error)
	process.exit(1)
})
