/**
 * Bisect CoNET top-up revert via eth_call step simulation.
 * Usage: npx tsx scripts/bisectConetTopupRevert.ts
 */
import { ethers } from 'ethers'

const RPC = process.env.CONET_RPC ?? 'https://publicrpc.conet.network'
const CARD = '0x703Ca8Bad6A1266Afc077a5B9F3dE0461F5560ff'
const FACTORY = '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'
const POS = '0xCAe6FfaC404c46D771B61B8027d2cd9860eE7290'
const RECIPIENT = '0x3Ca84050541F4A2f570F717C9D52624161dFaa7f'
const AA = '0x2A6401E54aaF83918793bC72F3cdF3eA24CD7bAF'
const POINTS = 100_000_000n
const MSM = '0xB7fac2D11F9cda14Cc8b414c99625077B4F7f2F1'

const ERROR_IFACE = new ethers.Interface([
	'error UC_RedeemDelegateFailed(bytes data)',
	'error UC_BelowMinThreshold()',
	'error UC_ResolveAccountFailed(address eoa, address aaFactory, address acct)',
	'error UC_NotAdmin()',
	'error UC_UnauthorizedGateway()',
	'error UC_AdminAirdropLimitExceeded(address admin, uint256 used, uint256 requested, uint256 limit)',
	'error UC_AlreadyHasValidCard()',
	'error UC_MustGrow()',
	'error BM_CallFailed()',
	'error BM_NotAuthorized()',
	'error UC_NoBeamioAccount()',
	'error UC_GlobalMisconfigured()',
])

function decodeRevert(err: unknown): string {
	const e = err as { data?: string; info?: { error?: { data?: string } }; shortMessage?: string }
	const data = e?.data ?? e?.info?.error?.data
	if (!data || data === '0x') return `empty revert (0x) ${e?.shortMessage ?? ''}`.trim()
	try {
		const parsed = ERROR_IFACE.parseError(data)
		if (parsed) return `${parsed.name}(${parsed.args.map(String).join(', ')})`
	} catch {
		/* fall through */
	}
	return data
}

async function tryCall(label: string, provider: ethers.JsonRpcProvider, req: ethers.TransactionRequest) {
	try {
		const out = await provider.call(req)
		console.log(`OK   ${label}`, out === '0x' ? '' : out.slice(0, 66))
		return true
	} catch (err) {
		console.log(`FAIL ${label}:`, decodeRevert(err))
		return false
	}
}

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	const cardIface = new ethers.Interface([
		'function mintPointsByAdmin(address,uint256)',
		'function mintPointsByAdminWithOperator(address,uint256,address)',
		'function balanceOf(address,uint256) view returns (uint256)',
		'function tiers(uint256) view returns (uint256,uint256,uint256)',
	])

	console.log('=== direct card entrypoints (from factory) ===')
	const mintAdmin = cardIface.encodeFunctionData('mintPointsByAdmin', [RECIPIENT, POINTS])
	const mintOp = cardIface.encodeFunctionData('mintPointsByAdminWithOperator', [RECIPIENT, POINTS, POS])
	await tryCall('mintPointsByAdmin', provider, { from: FACTORY, to: CARD, data: mintAdmin })
	await tryCall('mintPointsByAdminWithOperator', provider, { from: FACTORY, to: CARD, data: mintOp })

	console.log('\n=== membership module delegatecall via card (onlySelf) — simulate with eth_call to cardSelfCallModule impossible ===')
	console.log('=== instead: raw delegatecall simulation at block via custom eth_call not available ===')

	// Simulate delegatecall context: call MSM functions with `to: CARD` and `from: CARD` won't work externally.
	// Use eth_call state override trick: none on public RPC.
	// Proxy: call card with executeForAdmin full path from factory.

	const factoryIface = new ethers.Interface([
		'function executeForAdmin(address card,bytes data,uint256 deadline,uint256 nonce,bytes signature)',
	])
	// We cannot forge signature easily; stick to gateway paths above.

	console.log('\n=== membership module selectors (standalone eth_call — wrong context) ===')
	const msmIface = new ethers.Interface([
		'function syncActiveToBestValid(address)',
		'function maybeIssueOnlyIfNoneOrExpiredByPointsDelta(address,uint256)',
		'function maybeUpgrade(address,uint256)',
	])
	await tryCall('msm.syncActiveToBestValid(AA)', provider, {
		to: MSM,
		data: msmIface.encodeFunctionData('syncActiveToBestValid', [AA]),
	})
	await tryCall('msm.maybeIssue(AA, points)', provider, {
		to: MSM,
		data: msmIface.encodeFunctionData('maybeIssueOnlyIfNoneOrExpiredByPointsDelta', [AA, POINTS]),
	})
	await tryCall('msm.maybeUpgrade(AA, points)', provider, {
		to: MSM,
		data: msmIface.encodeFunctionData('maybeUpgrade', [AA, POINTS]),
	})

	console.log('\n=== smaller mint amounts ===')
	for (const amt of [5_000_000n, 1_000_000n, 100_000n]) {
		const data = cardIface.encodeFunctionData('mintPointsByAdmin', [RECIPIENT, amt])
		await tryCall(`mintPointsByAdmin amount=${amt}`, provider, { from: FACTORY, to: CARD, data })
	}

	console.log('\n=== mint to owner EOA instead of recipient ===')
	const owner = await provider.call({ to: CARD, data: ethers.id('owner()').slice(0, 10) }).then((r) =>
		ethers.getAddress('0x' + r.slice(-40))
	)
	console.log('owner', owner)
	await tryCall('mintPointsByAdmin to owner', provider, {
		from: FACTORY,
		to: CARD,
		data: cardIface.encodeFunctionData('mintPointsByAdmin', [owner, POINTS]),
	})

	console.log('\n=== check tiers readable ===')
	await tryCall('tiers(0)', provider, {
		to: CARD,
		data: cardIface.encodeFunctionData('tiers', [0]),
	})
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
