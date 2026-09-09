/**
 * CoNET UserCard beacon.upgradeTo (VERSION 21).
 *
 * Does NOT redeploy the beacon or change Factory bytecode.
 * Prefers library addresses from deployments/conet-UserCardBeacon.json + chainAddresses seeds.
 *
 * V21: Discover Gift redeem claim — RedeemGatewayLib peeks giftSplits before consume;
 * non-member fee → mintMemberCardInternal(tier 0) + #0 topup only; member → full #0.
 * Pair with RedeemModule.createGiftRedeemForPayer + AdminStats V6 gift selectors
 * (`upgradeMerchantGiftRedeemConet.ts`).
 * V20: all initial tier schedules are configured by BeaconProxy initializer;
 * direct-purchase fee tiers are canonical `tiers[0..n]` entries. TierOps and
 * MembershipFeeOps are linked libraries.
 * V19: burnPointsByAdmin (POS Charge settle) → UpdateLib.afterAdminPointsBurn →
 * same-cycle actor+referrer #13 (parity with real #0 transfer path).
 * V18: 3-arg `appendTier(minUsdc6, attr, expiry)` so live Factory AndTiers (`0x9a7eb0f0`)
 * can finish create + loyalty tiers in one tx. 4-arg overload remains for recover.
 * V17: GatewayMintLib unpacks TopupMintAmountCodec (total|#0 mint; raw passed to
 * recordTopup for paid|#13 base). Pair with ChargeRewardModuleV2 + AdminStats V6
 * (`upgradeChargeRewardTopupRatioConet.ts`).
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeUserCardBeaconConet.ts
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   FORCE_REDEPLOY_LIBS=1 — redeploy linked libs even if runtime matches
 *   SKIP_ACCEPT=1 — skip live ChargeReward / getRewardRule smoke
 *   ACCEPT_DEPLOY_SMOKE=0 — do not deploy a one-off smoke BeaconProxy
 *   SKIP_VERIFY=1 — forbidden unless the user authorized skip in the same message
 */
import fs from 'fs'
import path from 'path'
import { homedir } from 'os'
import { spawnSync } from 'child_process'
import { ethers } from 'ethers'
import { acceptUserCardBeacon } from './acceptUserCardBeaconConet.ts'

const CHAIN_ID = 224422
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const FACTORY =
	process.env.CONET_CARD_FACTORY || '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'
const FACTORY_OWNER = '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
const IMPL_OWNER_SENTINEL = '0x000000000000000000000000000000000000dEaD'
const BLOCKSCOUT = process.env.CONET_BLOCKSCOUT_URL || 'https://mainnet.conet.network'
const EIP170_MAX = 24576
const EXPECTED_VERSION = 21

/** Seeds when snap.libraryLinks lacks a key (must match live CoNET if reusing). */
const SEED = {
	BeamioUserCardFormattingLib: '0x62F18eeC53B423bb36246856Fe2216A7Df270873',
	BeamioUserCardTransferLib: '0x91700d6c4d6384C9515809484FC6ECfA786BeA04',
	BeamioUserCardViewsLib: '0x1c7c122429Da18e6078d9CEbb7B5b30F0Aa2a033',
	BeamioUserCardGatewayMintLib: '0xDe540aB16273683771F26e5Bae094dec11947547',
	BeamioUserCardModuleRouterLib: '0x1619a3Ce48C6B45d743E0C8E4636221FfEa88Bc9',
	BeamioUserCardAdminGatewayLib: '0x6BD214563ba5D4b5EE17E6C7E997bAE5cdB199D9',
	BeamioUserCardRedeemGatewayLib: '0x87134Bf71d87806EB28C12900276AFd4D8C45255',
	BeamioUserCardReferrerLib: '0xf20524D0D08c403CF0b80cADdf7098B12AAA74c2',
	BeamioUserCardUpdateLib: '0xd663B6A9fFC614C4e290F15F1B2C5227Aa5aB722',
	ReferrerRegistryLib: '0x695b8C50c2C5F24928abdf3A061ED383AaEBDc1B',
} as const

type Artifact = {
	abi: ethers.InterfaceAbi
	bytecode: string
	deployedBytecode?: string
	linkReferences?: Record<string, Record<string, Array<{ start: number; length: number }>>>
	immutableReferences?: Record<string, Array<{ start: number; length: number }>>
}

type BeaconSnap = {
	network: string
	chainId: number
	timestamp: string
	factory: string
	signer: string
	beaconOwner: string
	implOwnerSentinel: string
	deployBlock: number
	libraryLinks: {
		BeamioUserCardFormattingLib: string
		BeamioUserCardTransferLib: string
		BeamioUserCardViewsLib: string
		BeamioUserCardGatewayMintLib?: string
		BeamioUserCardModuleRouterLib?: string
		BeamioUserCardAdminGatewayLib?: string
		BeamioUserCardRedeemGatewayLib?: string
		BeamioUserCardUpdateLib?: string
		BeamioUserCardReferrerLib?: string
		ReferrerRegistryLib?: string
		BeamioUserCardTierOpsLib?: string
		MembershipFeeOpsLib?: string
	}
	reusedLibraries: Record<string, boolean>
	impl: string
	previousImpl?: string
	beacon: string
	implDeployedSize: number
	constructorArgs: Record<string, unknown>
	issuedNftModule?: string
	issuedNftModuleUpdatedFrom?: string
	issuedNftModuleUpdateTx?: string
	upgrades?: Array<{
		at: string
		from: string
		to: string
		tx: string
		version: number
	}>
	note: string
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

function loadArtifact(rel: string): Artifact {
	const p = path.join(process.cwd(), 'artifacts', rel)
	const j = JSON.parse(fs.readFileSync(p, 'utf-8')) as Artifact
	if (!j.bytecode || j.bytecode === '0x') throw new Error(`Missing bytecode: ${rel}`)
	return j
}

function loadSnap(): BeaconSnap {
	const p = path.join(process.cwd(), 'deployments', 'conet-UserCardBeacon.json')
	return JSON.parse(fs.readFileSync(p, 'utf-8')) as BeaconSnap
}

function linkBytecode(
	bytecode: string,
	linkReferences: Artifact['linkReferences'],
	libraries: Record<string, string>,
): string {
	let linked = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode
	const bodyLen = linked.length
	for (const [filePath, fileRefs] of Object.entries(linkReferences || {})) {
		for (const [libName, places] of Object.entries(fileRefs)) {
			const addr = libraries[libName]
			if (!addr) throw new Error(`Missing library address for ${libName}`)
			const hex = addr.replace(/^0x/, '').toLowerCase().padStart(40, '0')
			if (hex.length !== 40) throw new Error(`Bad library address ${libName}=${addr}`)
			// Creation-bytecode offsets (skip when linking deployedBytecode — offsets out of range).
			for (const { start, length } of places) {
				if (length !== 20) throw new Error(`Unexpected link length ${length} for ${libName}`)
				const startHex = start * 2
				if (startHex + 40 > bodyLen) continue
				linked = linked.slice(0, startHex) + hex + linked.slice(startHex + 40)
			}
			// Hardhat deployedBytecode keeps `__$<keccak256(fqn)[0:34]>$__` placeholders.
			const fqn = `${filePath}:${libName}`
			const ph = `__$${ethers.id(fqn).slice(2, 36)}$__`
			if (linked.includes(ph)) {
				linked = linked.split(ph).join(hex)
			}
		}
	}
	if (linked.includes('__')) {
		const left = linked.match(/__\$[0-9a-fA-F]{34}\$__/g)
		throw new Error(
			`Bytecode still has unresolved library placeholders: ${(left || []).join(', ')}`,
		)
	}
	return `0x${linked}`
}

function normalizeHex(raw: string): string {
	const h = (raw || '0x').toLowerCase()
	return h.startsWith('0x') ? h : `0x${h}`
}

function codeSize(hex: string): number {
	const body = normalizeHex(hex)
	if (body === '0x') return 0
	return (body.length - 2) / 2
}

async function runtimeMatches(
	provider: ethers.JsonRpcProvider,
	addr: string,
	localDeployed: string | undefined,
): Promise<boolean> {
	if (!addr || !ethers.isAddress(addr) || addr === ethers.ZeroAddress) return false
	if (!localDeployed || localDeployed === '0x') return false
	const onchain = normalizeHex(await provider.getCode(addr))
	if (onchain === '0x') return false
	return onchain === normalizeHex(localDeployed)
}

/** Linked deployedBytecode for nested-lib match checks. */
function linkedDeployedBytecode(
	art: Artifact,
	libraries: Record<string, string>,
): string | undefined {
	if (!art.deployedBytecode || art.deployedBytecode === '0x') return undefined
	if (!art.linkReferences || Object.keys(art.linkReferences).length === 0) {
		return art.deployedBytecode
	}
	return linkBytecode(art.deployedBytecode, art.linkReferences, libraries)
}

/**
 * Solidity libraries embed their own deployed address in runtime bytecode
 * (`library_deploy_address`). Artifacts retain this 32-byte word as zeroes,
 * so compare it after materializing the candidate library address. Without
 * this step every deployed library is a false mismatch and gets redeployed.
 */
function libraryRuntimeAtAddress(art: Artifact, libraryAddress: string, libraries: Record<string, string> = {}): string | undefined {
	let runtime = linkedDeployedBytecode(art, libraries)
	if (!runtime || runtime === '0x') return runtime
	const selfRefs = art.immutableReferences?.library_deploy_address ?? []
	if (selfRefs.length === 0) return runtime

	let body = runtime.slice(2)
	const encodedAddress = ethers.zeroPadValue(ethers.getAddress(libraryAddress), 32).slice(2).toLowerCase()
	for (const { start, length } of selfRefs) {
		if (length !== 32) throw new Error(`Unexpected library_deploy_address length ${length}`)
		const startHex = start * 2
		body = body.slice(0, startHex) + encodedAddress + body.slice(startHex + length * 2)
	}
	return `0x${body}`
}

async function deployPlain(
	wallet: ethers.Wallet,
	art: Artifact,
	label: string,
): Promise<string> {
	const factory = new ethers.ContractFactory(art.abi, art.bytecode, wallet)
	console.log(`[upgrade] deploying ${label}…`)
	const c = await factory.deploy()
	await c.waitForDeployment()
	const addr = await c.getAddress()
	console.log(`[upgrade] ${label}=${addr}`)
	return ethers.getAddress(addr)
}

async function deployLinked(
	wallet: ethers.Wallet,
	art: Artifact,
	libraries: Record<string, string>,
	label: string,
): Promise<string> {
	const linked = linkBytecode(art.bytecode, art.linkReferences, libraries)
	const factory = new ethers.ContractFactory(art.abi, linked, wallet)
	console.log(`[upgrade] deploying ${label} (linked)…`)
	const c = await factory.deploy()
	await c.waitForDeployment()
	const addr = await c.getAddress()
	console.log(`[upgrade] ${label}=${addr}`)
	return ethers.getAddress(addr)
}

function pickAddr(snapVal: string | undefined, seed: string): string {
	if (snapVal && ethers.isAddress(snapVal) && snapVal !== ethers.ZeroAddress) {
		return ethers.getAddress(snapVal)
	}
	return ethers.getAddress(seed)
}

function replaceSdkConst(src: string, name: string, value: string): string {
	const quoted = new RegExp(`export const ${name} = '[^']*'`)
	if (quoted.test(src)) {
		return src.replace(quoted, `export const ${name} = '${value}'`)
	}
	const envFallback = new RegExp(
		`export const ${name} = process\\.env\\.${name}\\?\\.trim\\(\\) \\|\\| '[^']*'`,
	)
	if (envFallback.test(src)) {
		return src.replace(envFallback, `export const ${name} = process.env.${name}?.trim() || '${value}'`)
	}
	throw new Error(`Could not update ${name} in chainAddresses.ts`)
}

function runChecked(command: string, args: string[]): void {
	console.log(`[upgrade] ${command} ${args.join(' ')}`)
	const result = spawnSync(command, args, {
		cwd: process.cwd(),
		stdio: 'inherit',
	})
	if (result.status !== 0) {
		throw new Error(`${command} ${args.join(' ')} failed with status ${result.status ?? 'unknown'}`)
	}
}

async function checkVerified(addr: string): Promise<boolean> {
	const r = await fetch(`${BLOCKSCOUT}/api/v2/smart-contracts/${addr}`)
	if (!r.ok) return false
	const d = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean }
	return Boolean(d.is_verified || d.is_partially_verified)
}

async function main(): Promise<void> {
	if (process.env.SKIP_VERIFY === '1') {
		throw new Error('SKIP_VERIFY=1 is forbidden unless explicitly authorized for this deployment')
	}
	const reuseImplEnv = (process.env.REUSE_IMPL || '').trim()
	if (reuseImplEnv && process.env.ALLOW_REUSE_IMPL !== '1') {
		throw new Error(
			'REUSE_IMPL is disabled for V20 upgrades. Refusing before any library deployment; deploy a fresh implementation instead.',
		)
	}
	runChecked('npm', ['run', 'clean'])
	runChecked('npm', ['run', 'compile'])

	const snap = loadSnap()
	const beaconAddr = ethers.getAddress(snap.beacon)
	const provider = new ethers.JsonRpcProvider(RPC)
	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) {
		throw new Error(`Wrong chainId ${net.chainId}; expected ${CHAIN_ID}`)
	}

	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	const balance = await provider.getBalance(wallet.address)
	console.log(`[upgrade] deployer=${wallet.address} beacon=${beaconAddr}`)
	console.log(`[upgrade] balance=${ethers.formatEther(balance)} CNET`)
	if (balance === 0n) throw new Error('Deployer CNET balance is 0')

	const beacon = new ethers.Contract(
		beaconAddr,
		[
			'function implementation() view returns (address)',
			'function owner() view returns (address)',
			'function upgradeTo(address newImplementation)',
		],
		wallet,
	)
	const previousImpl = ethers.getAddress(await beacon.implementation())
	const beaconOwner = ethers.getAddress(await beacon.owner())
	console.log(`[upgrade] current impl=${previousImpl}`)
	console.log(`[upgrade] beacon.owner=${beaconOwner}`)
	if (beaconOwner.toLowerCase() !== FACTORY_OWNER.toLowerCase()) {
		throw new Error(`beacon.owner() != factory owner ${FACTORY_OWNER}`)
	}

	const forceLibs = process.env.FORCE_REDEPLOY_LIBS === '1'
	const fmtArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardFormattingLib.sol/BeamioUserCardFormattingLib.json',
	)
	const xferArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardTransferLib.sol/BeamioUserCardTransferLib.json',
	)
	const viewsArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardViewsLib.sol/BeamioUserCardViewsLib.json',
	)
	const gatewayMintArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardGatewayMintLib.sol/BeamioUserCardGatewayMintLib.json',
	)
	const moduleRouterArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardModuleRouterLib.sol/BeamioUserCardModuleRouterLib.json',
	)
	const adminGatewayArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardAdminGatewayLib.sol/BeamioUserCardAdminGatewayLib.json',
	)
	const redeemGatewayArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardRedeemGatewayLib.sol/BeamioUserCardRedeemGatewayLib.json',
	)
	const registryArt = loadArtifact(
		'src/BeamioUserCard/ReferrerRegistryLib.sol/ReferrerRegistryLib.json',
	)
	const referrerArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardReferrerLib.sol/BeamioUserCardReferrerLib.json',
	)
	const updateArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardUpdateLib.sol/BeamioUserCardUpdateLib.json',
	)
	const membershipFeeOpsArt = loadArtifact(
		'src/BeamioUserCard/MembershipFeeOpsLib.sol/MembershipFeeOpsLib.json',
	)
	const tierOpsArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardTierOpsLib.sol/BeamioUserCardTierOpsLib.json',
	)
	const issuedNftArt = loadArtifact(
		'src/BeamioUserCard/IssuedNftModuleV2.sol/BeamioUserCardIssuedNftModuleV2.json',
	)
	const cardArt = loadArtifact('src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json')

	const reused: Record<string, boolean> = {}
	let formattingLib = pickAddr(snap.libraryLinks.BeamioUserCardFormattingLib, SEED.BeamioUserCardFormattingLib)
	let transferLib = pickAddr(snap.libraryLinks.BeamioUserCardTransferLib, SEED.BeamioUserCardTransferLib)
	let viewsLib = pickAddr(snap.libraryLinks.BeamioUserCardViewsLib, SEED.BeamioUserCardViewsLib)
	let gatewayMintLib = pickAddr(
		snap.libraryLinks.BeamioUserCardGatewayMintLib,
		SEED.BeamioUserCardGatewayMintLib,
	)
	let moduleRouterLib = pickAddr(
		snap.libraryLinks.BeamioUserCardModuleRouterLib,
		SEED.BeamioUserCardModuleRouterLib,
	)
	let adminGatewayLib = pickAddr(
		snap.libraryLinks.BeamioUserCardAdminGatewayLib,
		SEED.BeamioUserCardAdminGatewayLib,
	)
	let redeemGatewayLib = pickAddr(
		snap.libraryLinks.BeamioUserCardRedeemGatewayLib,
		SEED.BeamioUserCardRedeemGatewayLib,
	)
	let registryLib = pickAddr(snap.libraryLinks.ReferrerRegistryLib, SEED.ReferrerRegistryLib)
	let referrerLib = pickAddr(snap.libraryLinks.BeamioUserCardReferrerLib, SEED.BeamioUserCardReferrerLib)
	let updateLib = pickAddr(snap.libraryLinks.BeamioUserCardUpdateLib, SEED.BeamioUserCardUpdateLib)
	let membershipFeeOpsLib = snap.libraryLinks.MembershipFeeOpsLib
		? ethers.getAddress(snap.libraryLinks.MembershipFeeOpsLib)
		: ethers.ZeroAddress
	let tierOpsLib = snap.libraryLinks.BeamioUserCardTierOpsLib
		? ethers.getAddress(snap.libraryLinks.BeamioUserCardTierOpsLib)
		: ethers.ZeroAddress

	const fmtMatch =
		!forceLibs &&
		(await runtimeMatches(provider, formattingLib, libraryRuntimeAtAddress(fmtArt, formattingLib)))
	const xferMatch =
		!forceLibs &&
		(await runtimeMatches(provider, transferLib, libraryRuntimeAtAddress(xferArt, transferLib)))
	const viewsMatch =
		!forceLibs &&
		(await runtimeMatches(provider, viewsLib, libraryRuntimeAtAddress(viewsArt, viewsLib)))
	const gatewayMintMatch =
		!forceLibs &&
		(await runtimeMatches(
			provider,
			gatewayMintLib,
			libraryRuntimeAtAddress(gatewayMintArt, gatewayMintLib),
		))
	const moduleRouterMatch =
		!forceLibs &&
		(await runtimeMatches(
			provider,
			moduleRouterLib,
			libraryRuntimeAtAddress(moduleRouterArt, moduleRouterLib),
		))
	const adminGatewayMatch =
		!forceLibs &&
		(await runtimeMatches(
			provider,
			adminGatewayLib,
			libraryRuntimeAtAddress(adminGatewayArt, adminGatewayLib),
		))
	const redeemGatewayMatch =
		!forceLibs &&
		(await runtimeMatches(
			provider,
			redeemGatewayLib,
			libraryRuntimeAtAddress(redeemGatewayArt, redeemGatewayLib),
		))
	const registryMatch =
		!forceLibs &&
		(await runtimeMatches(provider, registryLib, libraryRuntimeAtAddress(registryArt, registryLib)))
	const membershipFeeOpsMatch =
		membershipFeeOpsLib !== ethers.ZeroAddress &&
		!forceLibs &&
		(await runtimeMatches(
			provider,
			membershipFeeOpsLib,
			libraryRuntimeAtAddress(membershipFeeOpsArt, membershipFeeOpsLib),
		))

	reused.BeamioUserCardFormattingLib = fmtMatch
	reused.BeamioUserCardTransferLib = xferMatch
	reused.BeamioUserCardViewsLib = viewsMatch
	reused.BeamioUserCardGatewayMintLib = gatewayMintMatch
	reused.BeamioUserCardModuleRouterLib = moduleRouterMatch
	reused.BeamioUserCardAdminGatewayLib = adminGatewayMatch
	reused.BeamioUserCardRedeemGatewayLib = redeemGatewayMatch
	reused.ReferrerRegistryLib = registryMatch
	reused.MembershipFeeOpsLib = membershipFeeOpsMatch

	console.log(`[upgrade] FormattingLib reuse=${fmtMatch} ${formattingLib}`)
	console.log(`[upgrade] TransferLib reuse=${xferMatch} ${transferLib}`)
	console.log(`[upgrade] ViewsLib reuse=${viewsMatch} ${viewsLib}`)
	console.log(`[upgrade] GatewayMintLib reuse=${gatewayMintMatch} ${gatewayMintLib}`)
	console.log(`[upgrade] ModuleRouterLib reuse=${moduleRouterMatch} ${moduleRouterLib}`)
	console.log(`[upgrade] AdminGatewayLib reuse=${adminGatewayMatch} ${adminGatewayLib}`)
	console.log(`[upgrade] RedeemGatewayLib reuse=${redeemGatewayMatch} ${redeemGatewayLib}`)
	console.log(`[upgrade] ReferrerRegistryLib reuse=${registryMatch} ${registryLib}`)
	console.log(`[upgrade] MembershipFeeOpsLib reuse=${membershipFeeOpsMatch} ${membershipFeeOpsLib}`)

	if (!fmtMatch) formattingLib = await deployPlain(wallet, fmtArt, 'BeamioUserCardFormattingLib')
	if (!xferMatch) transferLib = await deployPlain(wallet, xferArt, 'BeamioUserCardTransferLib')
	if (!viewsMatch) viewsLib = await deployPlain(wallet, viewsArt, 'BeamioUserCardViewsLib')
	if (!gatewayMintMatch) {
		gatewayMintLib = await deployPlain(wallet, gatewayMintArt, 'BeamioUserCardGatewayMintLib')
	}
	if (!moduleRouterMatch) {
		moduleRouterLib = await deployPlain(wallet, moduleRouterArt, 'BeamioUserCardModuleRouterLib')
	}
	if (!adminGatewayMatch) {
		adminGatewayLib = await deployPlain(wallet, adminGatewayArt, 'BeamioUserCardAdminGatewayLib')
	}
	if (!redeemGatewayMatch) {
		redeemGatewayLib = await deployPlain(wallet, redeemGatewayArt, 'BeamioUserCardRedeemGatewayLib')
	}
	if (!registryMatch) {
		registryLib = await deployPlain(wallet, registryArt, 'ReferrerRegistryLib')
	}
	if (!membershipFeeOpsMatch) {
		membershipFeeOpsLib = await deployPlain(wallet, membershipFeeOpsArt, 'MembershipFeeOpsLib')
	}

	const tierOpsLinkedDeployed = libraryRuntimeAtAddress(tierOpsArt, tierOpsLib, {
		MembershipFeeOpsLib: membershipFeeOpsLib,
	})
	const tierOpsMatch =
		tierOpsLib !== ethers.ZeroAddress &&
		!forceLibs &&
		(await runtimeMatches(provider, tierOpsLib, tierOpsLinkedDeployed))
	reused.BeamioUserCardTierOpsLib = tierOpsMatch
	console.log(`[upgrade] TierOpsLib reuse=${tierOpsMatch} ${tierOpsLib}`)
	if (!tierOpsMatch) {
		tierOpsLib = await deployLinked(
			wallet,
			tierOpsArt,
			{ MembershipFeeOpsLib: membershipFeeOpsLib },
			'BeamioUserCardTierOpsLib',
		)
	}

	const referrerLinkedDeployed = libraryRuntimeAtAddress(referrerArt, referrerLib, {
		ReferrerRegistryLib: registryLib,
	})
	const referrerMatch =
		!forceLibs && (await runtimeMatches(provider, referrerLib, referrerLinkedDeployed))
	reused.BeamioUserCardReferrerLib = referrerMatch
	console.log(`[upgrade] ReferrerLib reuse=${referrerMatch} ${referrerLib}`)
	if (!referrerMatch) {
		referrerLib = await deployLinked(
			wallet,
			referrerArt,
			{ ReferrerRegistryLib: registryLib },
			'BeamioUserCardReferrerLib',
		)
	}

	const updateLinkedDeployed = libraryRuntimeAtAddress(updateArt, updateLib, {
		BeamioUserCardReferrerLib: referrerLib,
		BeamioUserCardTransferLib: transferLib,
	})
	const updateMatch =
		!forceLibs && (await runtimeMatches(provider, updateLib, updateLinkedDeployed))
	reused.BeamioUserCardUpdateLib = updateMatch
	console.log(`[upgrade] UpdateLib reuse=${updateMatch} ${updateLib}`)
	if (!updateMatch) {
		updateLib = await deployLinked(
			wallet,
			updateArt,
			{
				BeamioUserCardReferrerLib: referrerLib,
				BeamioUserCardTransferLib: transferLib,
			},
			'BeamioUserCardUpdateLib',
		)
	}

	// V20 removes the internal cardSelfOwner selector. The current IssuedNft
	// module must therefore use the stable ERC-173 owner() getter before the
	// beacon begins routing cards to the V20 implementation.
	const factory = new ethers.Contract(
		FACTORY,
		[
			'function defaultIssuedNftModule() view returns (address)',
			'function setIssuedNftModule(address module)',
		],
		wallet,
	)
	const previousIssuedNftModule = ethers.getAddress(await factory.defaultIssuedNftModule())
	const issuedNftMatch =
		!forceLibs &&
		(await runtimeMatches(provider, previousIssuedNftModule, issuedNftArt.deployedBytecode))
	let issuedNftModule = previousIssuedNftModule
	let issuedNftModuleUpdateTx: string | undefined
	console.log(`[upgrade] IssuedNftModuleV2 reuse=${issuedNftMatch} ${previousIssuedNftModule}`)
	if (!issuedNftMatch) {
		issuedNftModule = await deployPlain(wallet, issuedNftArt, 'BeamioUserCardIssuedNftModuleV2')
	}

	const cardLinkLibs: Record<string, string> = {
		BeamioUserCardFormattingLib: formattingLib,
		BeamioUserCardTransferLib: transferLib,
		BeamioUserCardViewsLib: viewsLib,
		BeamioUserCardGatewayMintLib: gatewayMintLib,
		BeamioUserCardModuleRouterLib: moduleRouterLib,
		BeamioUserCardAdminGatewayLib: adminGatewayLib,
		BeamioUserCardRedeemGatewayLib: redeemGatewayLib,
		BeamioUserCardUpdateLib: updateLib,
		BeamioUserCardTierOpsLib: tierOpsLib,
		BeamioUserCardReferrerLib: referrerLib,
		ReferrerRegistryLib: registryLib,
		MembershipFeeOpsLib: membershipFeeOpsLib,
	}
	// Fail fast if artifact expects a lib we forgot.
	for (const fileRefs of Object.values(cardArt.linkReferences || {})) {
		for (const libName of Object.keys(fileRefs)) {
			if (!cardLinkLibs[libName]) {
				throw new Error(`UserCard artifact links ${libName} but upgrade script has no address`)
			}
		}
	}

	const linked = linkBytecode(cardArt.bytecode, cardArt.linkReferences, cardLinkLibs)

	let implAddr: string
	let implSize = 0
	if (reuseImplEnv) {
		if (process.env.ALLOW_REUSE_IMPL !== '1') {
			throw new Error(
				'REUSE_IMPL is disabled for V20 upgrades. Deploy a fresh implementation; set ALLOW_REUSE_IMPL=1 only after proving the candidate runtime matches the current linked artifact.',
			)
		}
		if (!ethers.isAddress(reuseImplEnv)) {
			throw new Error(`REUSE_IMPL is not an address: ${reuseImplEnv}`)
		}
		implAddr = ethers.getAddress(reuseImplEnv)
		const reuseCode = await provider.getCode(implAddr)
		if (!reuseCode || reuseCode === '0x') {
			throw new Error(`REUSE_IMPL has no code: ${implAddr}`)
		}
		implSize = codeSize(reuseCode)
		console.log(`[upgrade] REUSE_IMPL=${implAddr} deployedSize=${implSize} (skip deploy)`)
		const expectedRuntime = linkedDeployedBytecode(cardArt, cardLinkLibs)
		if (expectedRuntime && normalizeHex(reuseCode) !== normalizeHex(expectedRuntime)) {
			throw new Error(
				`REUSE_IMPL runtime does not match the current linked BeamioUserCard artifact: ${implAddr}. Deploy a fresh implementation instead.`,
			)
		}
	} else {
		const CardFactory = new ethers.ContractFactory(cardArt.abi, linked, wallet)
		const feeData = await provider.getFeeData()
		const baseMaxFee = feeData.maxFeePerGas ?? feeData.gasPrice ?? 1_000_000_000n
		const basePriority = feeData.maxPriorityFeePerGas ?? 1_000_000_000n
		const feeMult = BigInt(Math.max(2, Number(process.env.UPGRADE_FEE_MULT || '3') || 3))
		const deployOverrides = {
			maxFeePerGas: baseMaxFee * feeMult,
			maxPriorityFeePerGas: basePriority * feeMult,
		}
		console.log(
			`[upgrade] deploying V${EXPECTED_VERSION} BeamioUserCard impl… maxFee=${deployOverrides.maxFeePerGas} priority=${deployOverrides.maxPriorityFeePerGas} (×${feeMult})`,
		)
		const impl = await CardFactory.deploy(
			'',
			0,
			0n,
			ethers.ZeroAddress,
			ethers.ZeroAddress,
			deployOverrides,
		)
		await impl.waitForDeployment()
		implAddr = ethers.getAddress(await impl.getAddress())
		const implCode = await provider.getCode(implAddr)
		implSize = codeSize(implCode)
		console.log(`[upgrade] impl=${implAddr} deployedSize=${implSize}`)
		if (implSize > EIP170_MAX) throw new Error(`EIP-170 exceeded: ${implSize}`)
		if (implSize === 0) throw new Error('impl has no code')
		if (implAddr.toLowerCase() === previousImpl.toLowerCase()) {
			throw new Error('new impl address equals previous impl')
		}
	}

	const implReader = new ethers.Contract(
		implAddr,
		['function VERSION() view returns (uint256)', 'function owner() view returns (address)'],
		provider,
	)
	const version = Number(await implReader.VERSION())
	const implOwner = await implReader.owner()
	console.log(`[upgrade] impl VERSION=${version} owner=${implOwner}`)
	if (version !== EXPECTED_VERSION) throw new Error(`Expected VERSION ${EXPECTED_VERSION}, got ${version}`)
	if (String(implOwner).toLowerCase() !== IMPL_OWNER_SENTINEL.toLowerCase()) {
		throw new Error(`Expected sentinel owner ${IMPL_OWNER_SENTINEL}, got ${implOwner}`)
	}
	if (implAddr.toLowerCase() === previousImpl.toLowerCase()) {
		throw new Error('impl address equals previous beacon implementation (nothing to upgrade)')
	}

	const feeData = await provider.getFeeData()
	const baseMaxFee = feeData.maxFeePerGas ?? feeData.gasPrice ?? 1_000_000_000n
	const basePriority = feeData.maxPriorityFeePerGas ?? 1_000_000_000n
	const feeMult = BigInt(Math.max(2, Number(process.env.UPGRADE_FEE_MULT || '3') || 3))
	const upgradeOverrides = {
		maxFeePerGas: baseMaxFee * feeMult,
		maxPriorityFeePerGas: basePriority * feeMult,
	}
	console.log(
		`[upgrade] beacon.upgradeTo(${implAddr}) maxFee=${upgradeOverrides.maxFeePerGas} priority=${upgradeOverrides.maxPriorityFeePerGas} (×${feeMult})`,
	)
	const tx = await beacon.upgradeTo(implAddr, upgradeOverrides)
	const receipt = await tx.wait()
	if (!receipt || receipt.status !== 1) throw new Error('upgradeTo failed')
	const pointed = ethers.getAddress(await beacon.implementation())
	console.log(`[upgrade] tx=${receipt.hash} implementation=${pointed}`)
	if (pointed.toLowerCase() !== implAddr.toLowerCase()) {
		throw new Error('beacon.implementation() != new impl after upgradeTo')
	}
	if (!issuedNftMatch) {
		const bindTx = await factory.setIssuedNftModule(issuedNftModule)
		const bindReceipt = await bindTx.wait()
		if (!bindReceipt || bindReceipt.status !== 1) throw new Error('setIssuedNftModule failed')
		const bound = ethers.getAddress(await factory.defaultIssuedNftModule())
		if (bound.toLowerCase() !== issuedNftModule.toLowerCase()) {
			throw new Error(`defaultIssuedNftModule() != ${issuedNftModule} after bind`)
		}
		issuedNftModuleUpdateTx = bindReceipt.hash
		console.log(`[upgrade] setIssuedNftModule tx=${bindReceipt.hash} bound=${bound}`)
	}

	const next: BeaconSnap = {
		...snap,
		timestamp: new Date().toISOString(),
		signer: wallet.address,
		previousImpl,
		impl: implAddr,
		implDeployedSize: implSize,
		libraryLinks: {
			BeamioUserCardFormattingLib: formattingLib,
			BeamioUserCardTransferLib: transferLib,
			BeamioUserCardViewsLib: viewsLib,
			BeamioUserCardGatewayMintLib: gatewayMintLib,
			BeamioUserCardModuleRouterLib: moduleRouterLib,
			BeamioUserCardAdminGatewayLib: adminGatewayLib,
			BeamioUserCardRedeemGatewayLib: redeemGatewayLib,
			BeamioUserCardUpdateLib: updateLib,
			BeamioUserCardReferrerLib: referrerLib,
			ReferrerRegistryLib: registryLib,
			BeamioUserCardTierOpsLib: tierOpsLib,
			MembershipFeeOpsLib: membershipFeeOpsLib,
		},
		reusedLibraries: reused,
		constructorArgs: {
			...snap.constructorArgs,
			impl: ['', 0, 0, ethers.ZeroAddress, ethers.ZeroAddress],
		},
		issuedNftModule,
		issuedNftModuleUpdatedFrom: issuedNftMatch ? undefined : previousIssuedNftModule,
		issuedNftModuleUpdateTx,
		upgrades: [
			...(snap.upgrades ?? []),
			{
				at: new Date().toISOString(),
				from: previousImpl,
				to: implAddr,
				tx: receipt.hash,
				version,
			},
		],
		note:
			'UserCard V20: BeaconProxy initializer atomically configures every tier schedule. Direct-purchase fee tiers are stored as canonical tiers[0..n]; one card uses exactly one qualification mode. Nested TierOps→MembershipFeeOps. Beacon + Factory bytecode unchanged. Old CREATE cards stay on prior impl.',
	}
	const outPath = path.join(process.cwd(), 'deployments', 'conet-UserCardBeacon.json')
	fs.writeFileSync(outPath, JSON.stringify(next, null, 2) + '\n')
	console.log(`[upgrade] wrote ${outPath}`)

	const addrPath = path.join(process.cwd(), 'deployments', 'conet-addresses.json')
	if (fs.existsSync(addrPath)) {
		const addrs = JSON.parse(fs.readFileSync(addrPath, 'utf-8')) as Record<string, unknown>
		addrs.UserCardBeacon = beaconAddr
		addrs.UserCardBeaconImpl = implAddr
		addrs.BeamioUserCardFormattingLib = formattingLib
		addrs.BeamioUserCardTransferLib = transferLib
		addrs.BeamioUserCardViewsLib = viewsLib
		addrs.BeamioUserCardGatewayMintLib = gatewayMintLib
		addrs.BeamioUserCardModuleRouterLib = moduleRouterLib
		addrs.BeamioUserCardAdminGatewayLib = adminGatewayLib
		addrs.BeamioUserCardRedeemGatewayLib = redeemGatewayLib
		addrs.BeamioUserCardUpdateLib = updateLib
		addrs.BeamioUserCardReferrerLib = referrerLib
		addrs.ReferrerRegistryLib = registryLib
		addrs.BeamioUserCardTierOpsLib = tierOpsLib
		addrs.MembershipFeeOpsLib = membershipFeeOpsLib
		fs.writeFileSync(addrPath, JSON.stringify(addrs, null, 2) + '\n')
		console.log(`[upgrade] updated ${addrPath}`)
	}

	const sdkAddrPath = path.join(process.cwd(), 'src/x402sdk/src/chainAddresses.ts')
	if (fs.existsSync(sdkAddrPath)) {
		let src = fs.readFileSync(sdkAddrPath, 'utf-8')
		src = replaceSdkConst(src, 'CONET_USER_CARD_BEACON_IMPL', implAddr)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_FORMATTING_LIB', formattingLib)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_TRANSFER_LIB', transferLib)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_VIEWS_LIB', viewsLib)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_GATEWAY_MINT_LIB', gatewayMintLib)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_MODULE_ROUTER_LIB', moduleRouterLib)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_ADMIN_GATEWAY_LIB', adminGatewayLib)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_REDEEM_GATEWAY_LIB', redeemGatewayLib)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_UPDATE_LIB', updateLib)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_REFERRER_LIB', referrerLib)
		src = replaceSdkConst(src, 'CONET_REFERRER_REGISTRY_LIB', registryLib)
		src = replaceSdkConst(src, 'CONET_BEAMIO_USER_CARD_TIER_OPS_LIB', tierOpsLib)
		src = replaceSdkConst(src, 'CONET_MEMBERSHIP_FEE_OPS_LIB', membershipFeeOpsLib)
		fs.writeFileSync(sdkAddrPath, src)
		console.log('[upgrade] updated x402sdk CONET_USER_CARD_BEACON_IMPL + lib constants')
	}

	if (process.env.SKIP_ACCEPT !== '1') {
		await acceptUserCardBeacon({ provider, wallet })
	}

	for (const [name, addr] of [
		['FormattingLib', formattingLib],
		['TransferLib', transferLib],
		['ViewsLib', viewsLib],
		['GatewayMintLib', gatewayMintLib],
		['ModuleRouterLib', moduleRouterLib],
		['AdminGatewayLib', adminGatewayLib],
		['RedeemGatewayLib', redeemGatewayLib],
		['ReferrerRegistryLib', registryLib],
		['ReferrerLib', referrerLib],
		['UpdateLib', updateLib],
		['MembershipFeeOpsLib', membershipFeeOpsLib],
		['TierOpsLib', tierOpsLib],
		['IssuedNftModuleV2', issuedNftModule],
		['UserCardImpl', implAddr],
		['UserCardBeacon', beaconAddr],
	] as const) {
		const ok = await checkVerified(addr)
		console.log(`[verify-probe] ${name} ${addr} verified=${ok}`)
	}

	const verifyExports = new Set<string>([
		'BeamioUserCard',
		'BeamioUserCardUpgradeableBeacon',
	])
	for (const [key, wasReused] of Object.entries(reused)) {
		if (!wasReused) verifyExports.add(key)
	}
	if (!issuedNftMatch) verifyExports.add('BeamioUserCardIssuedNftModuleV2')
	for (const key of verifyExports) {
		runChecked(process.execPath, ['scripts/exportStandardJsonFromBuildInfo.mjs', key, '--full'])
	}
	runChecked('npx', ['tsx', 'scripts/verifyUserCardBeaconConet.ts'])
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
