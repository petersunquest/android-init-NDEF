import fs from 'node:fs'
import path from 'node:path'
import { homedir } from 'node:os'
import { ethers } from 'ethers'

const CHAIN_ID = 224422
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const FACTORY =
	process.env.CONET_CARD_FACTORY || '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'
const FACTORY_OWNER =
	process.env.FACTORY_OWNER || '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
const SNAPSHOT_PATH = 'deployments/conet-GovernanceOnlyGatewayFix.json'

type Artifact = {
	abi: ethers.InterfaceAbi
	bytecode: string
}

function loadOwnerKey(): string {
	const master = JSON.parse(
		fs.readFileSync(path.join(homedir(), '.master.json'), 'utf8'),
	) as {
		settle_contractAdmin?: string[]
		beamio_Admins?: string[]
	}
	for (const raw of [
		...(master.settle_contractAdmin ?? []),
		...(master.beamio_Admins ?? []),
	]) {
		const key = raw.startsWith('0x') ? raw : `0x${raw}`
		try {
			if (
				new ethers.Wallet(key).address.toLowerCase() ===
				FACTORY_OWNER.toLowerCase()
			) {
				return key
			}
		} catch {
			// Ignore malformed unrelated entries.
		}
	}
	throw new Error(`Factory owner key for ${FACTORY_OWNER} not found in local ~/.master.json`)
}

function loadArtifact(): Artifact {
	const artifactPath = path.join(
		process.cwd(),
		'artifacts/src/BeamioUserCard/GovernanceModule.sol/BeamioUserCardGovernanceModuleV1.json',
	)
	const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8')) as Artifact
	if (!artifact.bytecode || artifact.bytecode === '0x') {
		throw new Error(`Missing GovernanceModule bytecode: ${artifactPath}`)
	}
	return artifact
}

async function main(): Promise<void> {
	const provider = new ethers.JsonRpcProvider(RPC)
	const network = await provider.getNetwork()
	if (Number(network.chainId) !== CHAIN_ID) {
		throw new Error(`Wrong chainId ${network.chainId}; expected ${CHAIN_ID}`)
	}

	const signer = new ethers.NonceManager(new ethers.Wallet(loadOwnerKey(), provider))
	const factory = new ethers.Contract(
		FACTORY,
		[
			'function owner() view returns (address)',
			'function defaultGovernanceModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
			'function setGovernanceModule(address)',
		],
		signer,
	)
	const owner = String(await factory.owner())
	const signerAddress = await signer.getAddress()
	if (owner.toLowerCase() !== signerAddress.toLowerCase()) {
		throw new Error(`Signer ${signerAddress} is not Factory owner ${owner}`)
	}

	const previousGovernanceModule = String(await factory.defaultGovernanceModule())
	const adminStatsQueryModuleBefore = String(
		await factory.defaultAdminStatsQueryModule(),
	)
	const feeData = await provider.getFeeData()
	const gas: Record<string, bigint> = {}
	if (feeData.maxFeePerGas) gas.maxFeePerGas = feeData.maxFeePerGas * 2n
	if (feeData.maxPriorityFeePerGas) {
		gas.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas * 2n
	}

	const artifact = loadArtifact()
	const module = await new ethers.ContractFactory(
		artifact.abi,
		artifact.bytecode,
		signer,
	).deploy(gas)
	const deployTx = module.deploymentTransaction()
	await module.waitForDeployment()
	const governanceModule = await module.getAddress()
	if ((await provider.getCode(governanceModule)) === '0x') {
		throw new Error('GovernanceModule deployment has no code')
	}

	const bindTx = await factory.setGovernanceModule(governanceModule, gas)
	const bindReceipt = await bindTx.wait()
	if (!bindReceipt || bindReceipt.status !== 1) {
		throw new Error('setGovernanceModule transaction failed')
	}
	const boundGovernanceModule = String(await factory.defaultGovernanceModule())
	if (boundGovernanceModule.toLowerCase() !== governanceModule.toLowerCase()) {
		throw new Error(`Factory Governance binding mismatch: ${boundGovernanceModule}`)
	}
	const adminStatsQueryModuleAfter = String(
		await factory.defaultAdminStatsQueryModule(),
	)
	if (
		adminStatsQueryModuleAfter.toLowerCase() !==
		adminStatsQueryModuleBefore.toLowerCase()
	) {
		throw new Error(
			`AdminStats binding changed unexpectedly: ${adminStatsQueryModuleBefore} -> ${adminStatsQueryModuleAfter}`,
		)
	}

	const snapshot = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		rpc: RPC,
		factory: FACTORY,
		factoryOwner: owner,
		previousGovernanceModule,
		governanceModule,
		boundGovernanceModule,
		adminStatsQueryModuleBefore,
		adminStatsQueryModuleAfter,
		deployTx: deployTx?.hash ?? null,
		bindTx: bindReceipt.hash,
		fix: 'Governance onlyGateway accepts Factory gateway or card-internal self-call',
	}
	fs.writeFileSync(
		path.join(process.cwd(), SNAPSHOT_PATH),
		`${JSON.stringify(snapshot, null, 2)}\n`,
	)
	console.log(JSON.stringify(snapshot, null, 2))
	console.log(
		'Next: node scripts/exportStandardJsonFromBuildInfo.mjs GovernanceModule --full',
	)
	console.log('Next: node scripts/exportGovernanceModuleConetVerifyBuildinfo.mjs')
	console.log('Next: CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyGovernanceOnlyGatewayFixConet.ts')
}

main().catch((error) => {
	console.error(error)
	process.exit(1)
})
