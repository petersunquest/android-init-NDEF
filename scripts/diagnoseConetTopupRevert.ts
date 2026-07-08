/**
 * Diagnose CoNET NFC top-up revert for a merchant card.
 * Usage: npx tsx scripts/diagnoseConetTopupRevert.ts
 */
import { ethers } from 'ethers'

const RPC = process.env.CONEt_RPC ?? 'https://publicrpc.conet.network'
const CARD = '0x703Ca8Bad6A1266Afc077a5B9F3dE0461F5560ff'
const FACTORY = '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'
const POS = '0xCAe6FfaC404c46D771B61B8027d2cd9860eE7290'
const RECIPIENT = '0x3Ca84050541F4A2f570F717C9D52624161dFaa7f'
const AA = '0x2A6401E54aaF83918793bC72F3cdF3eA24CD7bAF'
const POINTS = 100_000_000n

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
])

function decodeRevert(err: unknown): string {
	const e = err as { data?: string; info?: { error?: { data?: string } } }
	const data = e?.data ?? e?.info?.error?.data
	if (!data || data === '0x') return 'empty revert (0x)'
	try {
		const parsed = ERROR_IFACE.parseError(data)
		if (parsed) return `${parsed.name}(${parsed.args.map(String).join(', ')})`
	} catch {
		/* fall through */
	}
	return data
}

async function tryCall(label: string, fn: () => Promise<unknown>) {
	try {
		const r = await fn()
		console.log(`OK  ${label}:`, r?.toString?.() ?? r)
	} catch (err) {
		console.log(`FAIL ${label}:`, decodeRevert(err))
	}
}

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	const card = new ethers.Contract(
		CARD,
		[
			'function mintPointsByAdmin(address,uint256)',
			'function mintPointsByAdminWithOperator(address,uint256,address)',
			'function factoryGateway() view returns (address)',
			'function tiersLength() view returns (uint256)',
			'function tiers(uint256) view returns (uint256,uint256,uint256,uint256)',
			'function activeMembershipId(address) view returns (uint256)',
			'function balanceOf(address,uint256) view returns (uint256)',
			'function isAdmin(address) view returns (bool)',
			'function cardUserCumulativeStatTokensInitialized() view returns (bool)',
			'function totalSupply(uint256) view returns (uint256)',
		],
		provider
	)

	console.log('=== card state ===')
	await tryCall('factoryGateway', () => card.factoryGateway())
	await tryCall('isAdmin POS', () => card.isAdmin(POS))
	await tryCall('tiersLength', () => card.tiersLength())
	await tryCall('tiers(0)', () => card.tiers(0))
	await tryCall('activeMembershipId AA', () => card.activeMembershipId(AA))
	await tryCall('balanceOf points AA', () => card.balanceOf(AA, 0))
	await tryCall('stat tokens initialized', () => card.cardUserCumulativeStatTokensInitialized())
	await tryCall('totalSupply(0)', () => card.totalSupply(0))

	const factory = new ethers.Contract(
		FACTORY,
		['function defaultModule(uint8) view returns (address)', 'function _aaFactory() view returns (address)'],
		provider
	)
	console.log('\n=== factory modules ===')
	for (let k = 0; k <= 5; k++) {
		await tryCall(`defaultModule(${k})`, () => factory.defaultModule(k))
	}

	const aaFactory = await factory._aaFactory()
	const aaFac = new ethers.Contract(
		aaFactory,
		['function beamioAccountOf(address) view returns (address)', 'function isBeamioAccount(address) view returns (bool)'],
		provider
	)
	console.log('\n=== AA ===')
	await tryCall('beamioAccountOf recipient', () => aaFac.beamioAccountOf(RECIPIENT))
	await tryCall('isBeamioAccount AA', () => aaFac.isBeamioAccount(AA))

	console.log('\n=== mint simulation (from factory) ===')
	const mintAdmin = card.interface.encodeFunctionData('mintPointsByAdmin', [RECIPIENT, POINTS])
	const mintOp = card.interface.encodeFunctionData('mintPointsByAdminWithOperator', [RECIPIENT, POINTS, POS])
	await tryCall('mintPointsByAdmin', () => provider.call({ from: FACTORY, to: CARD, data: mintAdmin }))
	await tryCall('mintPointsByAdminWithOperator', () => provider.call({ from: FACTORY, to: CARD, data: mintOp }))

	// Fallback-only module calls (expected BM_CallFailed if selector not routed)
	const syncSel = ethers.id('syncActiveToBestValid(address)').slice(0, 10)
	const syncData = syncSel + ethers.AbiCoder.defaultAbiCoder().encode(['address'], [AA]).slice(2)
	await tryCall('fallback syncActiveToBestValid', () => provider.call({ from: FACTORY, to: CARD, data: syncData }))

	// Direct module eth_call (standalone context — not delegatecall)
	const msm = await factory.defaultModule(4)
	const msmContract = new ethers.Contract(
		msm,
		['function syncActiveToBestValid(address)', 'function maybeIssueOnlyIfNoneOrExpiredByPointsDelta(address,uint256)'],
		provider
	)
	console.log('\n=== membership module direct (non-delegatecall) ===')
	await tryCall('msm.syncActiveToBestValid', () => msmContract.syncActiveToBestValid.staticCall(AA))
	await tryCall('msm.maybeIssue', () => msmContract.maybeIssueOnlyIfNoneOrExpiredByPointsDelta.staticCall(AA, POINTS))

	// Bisect: static-call view helpers exposed on card
	const gateAbi = [
		'function cardSelfToAccount(address) view returns (address)',
		'function cardSelfRequirePointsMintAllowsFirstMembership(address,uint256) view',
	]
	const gate = new ethers.Contract(CARD, gateAbi, provider)
	console.log('\n=== cardSelf* view probes ===')
	await tryCall('cardSelfToAccount', () => gate.cardSelfToAccount(RECIPIENT))
	await tryCall('requirePointsMintAllowsFirstMembership', () =>
		gate.cardSelfRequirePointsMintAllowsFirstMembership(AA, POINTS)
	)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
