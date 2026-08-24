/**
 * P3: First CoNET UserCard beacon.upgradeTo (VERSION 14).
 *
 * Does NOT redeploy the beacon or change Factory bytecode.
 * Prefers library addresses from deployments/conet-UserCardBeacon.json.
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeUserCardBeaconConet.ts
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   FORCE_REDEPLOY_LIBS=1 — redeploy Formatting/Transfer/Views even if runtime matches
 *   SKIP_ACCEPT=1 — skip live ChargeReward / getRewardRule smoke
 *   ACCEPT_DEPLOY_SMOKE=0 — do not deploy a one-off smoke BeaconProxy
 *   SKIP_VERIFY=1 — forbidden unless the user authorized skip in the same message
 */
import fs from 'fs'
import path from 'path'
import { homedir } from 'os'
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
const EXPECTED_VERSION = 14

type Artifact = {
	abi: ethers.InterfaceAbi
	bytecode: string
	deployedBytecode?: string
	linkReferences?: Record<string, Record<string, Array<{ start: number; length: number }>>>
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
	}
	reusedLibraries: Record<string, boolean>
	impl: string
	previousImpl?: string
	beacon: string
	implDeployedSize: number
	constructorArgs: Record<string, unknown>
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
	for (const fileRefs of Object.values(linkReferences || {})) {
		for (const [libName, places] of Object.entries(fileRefs)) {
			const addr = libraries[libName]
			if (!addr) throw new Error(`Missing library address for ${libName}`)
			const hex = addr.replace(/^0x/, '').toLowerCase().padStart(40, '0')
			if (hex.length !== 40) throw new Error(`Bad library address ${libName}=${addr}`)
			for (const { start, length } of places) {
				if (length !== 20) throw new Error(`Unexpected link length ${length} for ${libName}`)
				const startHex = start * 2
				linked = linked.slice(0, startHex) + hex + linked.slice(startHex + 40)
			}
		}
	}
	if (linked.includes('__')) {
		throw new Error('Bytecode still has unresolved library placeholders')
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

async function checkVerified(addr: string): Promise<boolean> {
	const r = await fetch(`${BLOCKSCOUT}/api/v2/smart-contracts/${addr}`)
	if (!r.ok) return false
	const d = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean }
	return Boolean(d.is_verified || d.is_partially_verified)
}

async function main(): Promise<void> {
	if (process.env.SKIP_VERIFY === '1') {
		console.warn(
			'[upgrade] SKIP_VERIFY=1 is set. Verification must still complete in this same task.',
		)
	}

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
	const cardArt = loadArtifact('src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json')

	const reused: Record<string, boolean> = {}
	let formattingLib = ethers.getAddress(snap.libraryLinks.BeamioUserCardFormattingLib)
	let transferLib = ethers.getAddress(snap.libraryLinks.BeamioUserCardTransferLib)
	let viewsLib = ethers.getAddress(snap.libraryLinks.BeamioUserCardViewsLib)

	const fmtMatch = !forceLibs && (await runtimeMatches(provider, formattingLib, fmtArt.deployedBytecode))
	const xferMatch = !forceLibs && (await runtimeMatches(provider, transferLib, xferArt.deployedBytecode))
	const viewsMatch = !forceLibs && (await runtimeMatches(provider, viewsLib, viewsArt.deployedBytecode))
	reused.BeamioUserCardFormattingLib = fmtMatch
	reused.BeamioUserCardTransferLib = xferMatch
	reused.BeamioUserCardViewsLib = viewsMatch
	console.log(`[upgrade] FormattingLib reuse=${fmtMatch} ${formattingLib}`)
	console.log(`[upgrade] TransferLib reuse=${xferMatch} ${transferLib}`)
	console.log(`[upgrade] ViewsLib reuse=${viewsMatch} ${viewsLib}`)

	if (!fmtMatch) formattingLib = await deployPlain(wallet, fmtArt, 'BeamioUserCardFormattingLib')
	if (!xferMatch) transferLib = await deployPlain(wallet, xferArt, 'BeamioUserCardTransferLib')
	if (!viewsMatch) viewsLib = await deployPlain(wallet, viewsArt, 'BeamioUserCardViewsLib')

	const linked = linkBytecode(cardArt.bytecode, cardArt.linkReferences, {
		BeamioUserCardFormattingLib: formattingLib,
		BeamioUserCardTransferLib: transferLib,
		BeamioUserCardViewsLib: viewsLib,
	})

	const CardFactory = new ethers.ContractFactory(cardArt.abi, linked, wallet)
	console.log('[upgrade] deploying V14 sentinel BeamioUserCard impl…')
	const impl = await CardFactory.deploy('', 0, 0n, ethers.ZeroAddress, ethers.ZeroAddress)
	await impl.waitForDeployment()
	const implAddr = ethers.getAddress(await impl.getAddress())
	const implCode = await provider.getCode(implAddr)
	const implSize = codeSize(implCode)
	console.log(`[upgrade] impl=${implAddr} deployedSize=${implSize}`)
	if (implSize > EIP170_MAX) throw new Error(`EIP-170 exceeded: ${implSize}`)
	if (implSize === 0) throw new Error('impl has no code')
	if (implAddr.toLowerCase() === previousImpl.toLowerCase()) {
		throw new Error('new impl address equals previous impl')
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

	console.log(`[upgrade] beacon.upgradeTo(${implAddr})`)
	const tx = await beacon.upgradeTo(implAddr)
	const receipt = await tx.wait()
	if (!receipt || receipt.status !== 1) throw new Error('upgradeTo failed')
	const pointed = ethers.getAddress(await beacon.implementation())
	console.log(`[upgrade] tx=${receipt.hash} implementation=${pointed}`)
	if (pointed.toLowerCase() !== implAddr.toLowerCase()) {
		throw new Error('beacon.implementation() != new impl after upgradeTo')
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
		},
		reusedLibraries: reused,
		constructorArgs: {
			...snap.constructorArgs,
			impl: ['', 0, 0, ethers.ZeroAddress, ethers.ZeroAddress],
		},
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
			'UserCard V14 first beacon.upgradeTo (P3). Beacon + Factory bytecode unchanged. Old CREATE cards stay on P0 preCheck.',
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
		fs.writeFileSync(sdkAddrPath, src)
		console.log('[upgrade] updated x402sdk CONET_USER_CARD_BEACON_IMPL + lib constants')
	}

	if (process.env.SKIP_ACCEPT !== '1') {
		await acceptUserCardBeacon({ provider, wallet })
	}

	if (process.env.SKIP_VERIFY !== '1') {
		for (const [name, addr] of [
			['FormattingLib', formattingLib],
			['TransferLib', transferLib],
			['ViewsLib', viewsLib],
			['UserCardImpl', implAddr],
			['UserCardBeacon', beaconAddr],
		] as const) {
			const ok = await checkVerified(addr)
			console.log(`[verify-probe] ${name} ${addr} verified=${ok}`)
		}
	}

	console.log('\nNext verify steps:')
	console.log('  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCard --full')
	if (!fmtMatch) {
		console.log('  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardFormattingLib --full')
	}
	if (!xferMatch) {
		console.log('  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardTransferLib --full')
	}
	if (!viewsMatch) {
		console.log('  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardViewsLib --full')
	}
	console.log('  CONET_VERIFY_ONLY=BeamioUserCard CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyUserCardBeaconConet.ts')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
