/**
 * P3 acceptance: Charge / Referrer / ruleId=2 surface on the live CoNET beacon stack.
 *
 * Reads the current Factory on CoNET (0xfA52…). Does not redeploy ChargeReward or AdminStats.
 * If no BeaconProxy card exists after the P2 deploy block, deploys a one-off smoke proxy
 * (ACCEPT_DEPLOY_SMOKE=0 to skip).
 *
 * Usage:
 *   npx tsx scripts/acceptUserCardBeaconConet.ts
 */
import fs from 'fs'
import path from 'path'
import { homedir } from 'os'
import { ethers } from 'ethers'

const CHAIN_ID = 224422
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const FACTORY =
	process.env.CONET_CARD_FACTORY || '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'
const FACTORY_OWNER = '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
const EIP1967_BEACON_SLOT =
	'0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50'
const INIT_NEEDLE = '631897af8914'
const LEGACY_NEEDLE = '610745613b8856'
const EXPECTED_VERSION = 14
const ROUTE_CHARGE_REWARD = 5
const LOG_WINDOW = 4990

const CONFIGURE_EVENT_REWARD_RULES_BATCH_SELECTOR = new ethers.Interface([
	'function configureEventRewardRulesBatch((uint256 ruleId,bool active,uint8 eventKind,uint8 targetKind,uint256 issuedParentId,uint256 actorMint13,uint256 refMint13)[] configs)',
]).getFunction('configureEventRewardRulesBatch')!.selector

type BeaconSnap = {
	beacon: string
	impl: string
	factory?: string
	deployBlock?: number
}

type Artifact = {
	abi: ethers.InterfaceAbi
	bytecode: string
}

export type AcceptResult = {
	ok: boolean
	beacon: string
	impl: string
	adminStats: string
	chargeRewardModule?: string
	proxyCards: string[]
	smokeCard?: string
	notes: string[]
}

function loadOwnerKey(): string {
	const masterPath = path.join(homedir(), '.master.json')
	const master = JSON.parse(fs.readFileSync(masterPath, 'utf-8')) as {
		settle_contractAdmin?: string[]
		beamio_Admins?: string[]
	}
	const keys = [...(master.settle_contractAdmin ?? []), ...(master.beamio_Admins ?? [])]
	const wanted = (process.env.FACTORY_OWNER || FACTORY_OWNER).toLowerCase()
	for (const raw of keys) {
		const key = raw.startsWith('0x') ? raw : `0x${raw}`
		try {
			if (new ethers.Wallet(key).address.toLowerCase() === wanted) return key
		} catch {
			/* skip */
		}
	}
	throw new Error(`Factory owner key for ${wanted} not found in ~/.master.json`)
}

function loadSnap(): BeaconSnap {
	const p = path.join(process.cwd(), 'deployments', 'conet-UserCardBeacon.json')
	return JSON.parse(fs.readFileSync(p, 'utf-8')) as BeaconSnap
}

function loadArtifact(rel: string): Artifact {
	const p = path.join(process.cwd(), 'artifacts', rel)
	return JSON.parse(fs.readFileSync(p, 'utf-8')) as Artifact
}

function slotAddress(word: string): string {
	if (!word || word === '0x') return ethers.ZeroAddress
	return ethers.getAddress(`0x${word.slice(-40)}`)
}

async function findBeaconProxyCards(
	provider: ethers.Provider,
	beacon: string,
	fromBlock: number,
): Promise<string[]> {
	const latest = await provider.getBlockNumber()
	const start = Math.max(fromBlock, latest - LOG_WINDOW)
	const factory = new ethers.Contract(
		FACTORY,
		['event CardDeployed(address indexed cardOwner, address indexed card, uint8 currency, uint256 priceE18)'],
		provider,
	)
	const logs = await factory.queryFilter(factory.filters.CardDeployed(), start, latest)
	const found: string[] = []
	for (const log of logs) {
		const card = (log as ethers.EventLog).args?.card as string | undefined
		if (!card || !ethers.isAddress(card)) continue
		const word = await provider.getStorage(card, EIP1967_BEACON_SLOT)
		if (slotAddress(word).toLowerCase() === beacon.toLowerCase()) {
			found.push(ethers.getAddress(card))
		}
	}
	return [...new Set(found)]
}

async function deploySmokeProxy(
	wallet: ethers.Wallet,
	beacon: string,
): Promise<string> {
	const cardArt = loadArtifact('src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json')
	const proxyArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardBeaconProxy.sol/BeamioUserCardBeaconProxy.json',
	)
	const iface = new ethers.Interface(cardArt.abi)
	const initData = iface.encodeFunctionData('initialize', [
		'https://beamio.app/api/metadata/0x',
		0,
		1_000_000n,
		wallet.address,
		FACTORY,
	])
	const ProxyFactory = new ethers.ContractFactory(proxyArt.abi, proxyArt.bytecode, wallet)
	console.log('[accept] deploying one-off BeaconProxy smoke card…')
	const proxy = await ProxyFactory.deploy(beacon, initData)
	await proxy.waitForDeployment()
	const addr = ethers.getAddress(await proxy.getAddress())
	console.log(`[accept] smokeCard=${addr}`)
	return addr
}

async function smokeCardViews(
	provider: ethers.Provider,
	card: string,
	implCode: string,
	expectedOwner?: string,
): Promise<string[]> {
	const notes: string[] = []
	const reader = new ethers.Contract(
		card,
		[
			'function VERSION() view returns (uint256)',
			'function owner() view returns (address)',
			'function factoryGateway() view returns (address)',
			'function getRewardRule(uint256 ruleId) view returns (bool active, uint8 eventKind, uint8 targetKind, uint256 issuedParentId, uint256 actorMint13, uint256 refMint13)',
		],
		provider,
	)
	const version = Number(await reader.VERSION())
	if (version !== EXPECTED_VERSION) {
		throw new Error(`card ${card} VERSION=${version}, expected ${EXPECTED_VERSION}`)
	}
	notes.push(`VERSION=${version}`)
	if (expectedOwner) {
		const owner = ethers.getAddress(await reader.owner())
		if (owner.toLowerCase() !== expectedOwner.toLowerCase()) {
			throw new Error(`card ${card} owner=${owner}, expected ${expectedOwner}`)
		}
	}
	try {
		await reader.getRewardRule(2)
		notes.push('getRewardRule(2) ok')
	} catch (e) {
		const msg = e instanceof Error ? e.message : String(e)
		if (msg.includes('BM_CallFailed')) {
			throw new Error(`card ${card} getRewardRule(2) BM_CallFailed`)
		}
		throw e
	}
	const lower = implCode.toLowerCase()
	if (!lower.includes(INIT_NEEDLE)) {
		throw new Error(`impl runtime missing initialize needle ${INIT_NEEDLE}`)
	}
	if (lower.includes(LEGACY_NEEDLE)) {
		throw new Error('impl runtime still has legacy ChargeReward-less needle')
	}
	notes.push('ChargeReward initialize needle present')
	return notes
}

export async function acceptUserCardBeacon(opts?: {
	provider?: ethers.JsonRpcProvider
	wallet?: ethers.Wallet
	deploySmokeIfMissing?: boolean
}): Promise<AcceptResult> {
	const snap = loadSnap()
	const beacon = ethers.getAddress(snap.beacon)
	const provider = opts?.provider ?? new ethers.JsonRpcProvider(RPC)
	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) {
		throw new Error(`Wrong chainId ${net.chainId}; expected ${CHAIN_ID}`)
	}

	const beaconReader = new ethers.Contract(
		beacon,
		['function implementation() view returns (address)', 'function owner() view returns (address)'],
		provider,
	)
	const impl = ethers.getAddress(await beaconReader.implementation())
	const implCode = await provider.getCode(impl)
	if (implCode === '0x') throw new Error(`beacon.implementation ${impl} has no code`)
	console.log(`[accept] beacon=${beacon} impl=${impl} implSize=${(implCode.length - 2) / 2}`)

	const factory = new ethers.Contract(
		FACTORY,
		[
			'function defaultAdminStatsQueryModule() view returns (address)',
			'function defaultChargeRewardModule() view returns (address)',
		],
		provider,
	)
	const adminStats = ethers.getAddress(await factory.defaultAdminStatsQueryModule())
	const adminCode = await provider.getCode(adminStats)
	if (adminCode === '0x') throw new Error(`defaultAdminStatsQueryModule ${adminStats} has no code`)
	console.log(`[accept] AdminStats=${adminStats}`)

	const adminReader = new ethers.Contract(
		adminStats,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	const kind = Number(
		await adminReader.selectorModuleKind(CONFIGURE_EVENT_REWARD_RULES_BATCH_SELECTOR),
	)
	console.log(
		`[accept] selectorModuleKind(${CONFIGURE_EVENT_REWARD_RULES_BATCH_SELECTOR})=${kind}`,
	)
	if (kind !== ROUTE_CHARGE_REWARD) {
		throw new Error(
			`AdminStats must route configureEventRewardRulesBatch to ChargeReward (${ROUTE_CHARGE_REWARD}), got ${kind}`,
		)
	}

	let chargeRewardModule: string | undefined
	try {
		chargeRewardModule = ethers.getAddress(await factory.defaultChargeRewardModule())
		const chargeCode = await provider.getCode(chargeRewardModule)
		if (chargeCode === '0x') {
			throw new Error(`defaultChargeRewardModule ${chargeRewardModule} has no code`)
		}
		console.log(`[accept] ChargeReward=${chargeRewardModule}`)
	} catch (e) {
		if (e instanceof Error && e.message.includes('has no code')) throw e
		console.log('[accept] Factory has no defaultChargeRewardModule getter; AdminStats route is the gate')
	}

	const fromBlock = Number(snap.deployBlock || 0)
	let proxyCards = await findBeaconProxyCards(provider, beacon, fromBlock)
	console.log(`[accept] BeaconProxy cards from logs=${proxyCards.length}`)

	const notes: string[] = []
	let smokeCard: string | undefined
	const deploySmoke =
		opts?.deploySmokeIfMissing ?? process.env.ACCEPT_DEPLOY_SMOKE !== '0'
	if (proxyCards.length === 0 && deploySmoke) {
		const wallet =
			opts?.wallet ?? new ethers.Wallet(loadOwnerKey(), provider)
		smokeCard = await deploySmokeProxy(wallet, beacon)
		proxyCards = [smokeCard]
		notes.push('deployed one-off smoke BeaconProxy (not a merchant card)')
	}
	if (proxyCards.length === 0) {
		throw new Error('No BeaconProxy card to smoke; set ACCEPT_DEPLOY_SMOKE=1 or pass a card')
	}

	const sample = proxyCards[0]
	const extra = await smokeCardViews(
		provider,
		sample,
		implCode,
		smokeCard ? (opts?.wallet?.address ?? (await new ethers.Wallet(loadOwnerKey()).getAddress())) : undefined,
	)
	notes.push(...extra)
	console.log(`[accept] smoked ${sample}: ${extra.join(', ')}`)

	const result: AcceptResult = {
		ok: true,
		beacon,
		impl,
		adminStats,
		chargeRewardModule,
		proxyCards,
		smokeCard,
		notes,
	}
	console.log('[accept] PASS Charge / Referrer / ruleId=2 surface')
	return result
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('acceptUserCardBeaconConet.ts')) {
	acceptUserCardBeacon().catch((e) => {
		console.error(e)
		process.exit(1)
	})
}
