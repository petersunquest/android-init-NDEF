import fs from 'node:fs'
import path from 'node:path'
import { homedir } from 'node:os'
import { ethers } from 'ethers'

const CHAIN_ID = 224422
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const FACTORY = process.env.CONET_CARD_FACTORY || '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'
const FACTORY_OWNER = process.env.FACTORY_OWNER || '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'

type Artifact = { abi: ethers.InterfaceAbi; bytecode: string }

function loadOwnerKey(): string {
	const master = JSON.parse(fs.readFileSync(path.join(homedir(), '.master.json'), 'utf8')) as {
		settle_contractAdmin?: string[]
		beamio_Admins?: string[]
	}
	const candidates = [...(master.settle_contractAdmin ?? []), ...(master.beamio_Admins ?? [])]
	for (const raw of candidates) {
		const key = raw.startsWith('0x') ? raw : `0x${raw}`
		try {
			if (new ethers.Wallet(key).address.toLowerCase() === FACTORY_OWNER.toLowerCase()) return key
		} catch {}
	}
	throw new Error(`Factory owner key for ${FACTORY_OWNER} was not found in local ~/.master.json`)
}

function loadArtifact(): Artifact {
	return JSON.parse(
		fs.readFileSync(
			path.join(process.cwd(), 'artifacts/src/BeamioUserCard/GovernanceModule.sol/BeamioUserCardGovernanceModuleV1.json'),
			'utf8',
		),
	) as Artifact
}

async function main(): Promise<void> {
	const provider = new ethers.JsonRpcProvider(RPC)
	const network = await provider.getNetwork()
	if (Number(network.chainId) !== CHAIN_ID) throw new Error(`Wrong chainId ${network.chainId}`)
	const wallet = new ethers.NonceManager(new ethers.Wallet(loadOwnerKey(), provider))
	const feeData = await provider.getFeeData()
	const gas: Record<string, bigint> = {}
	if (feeData.maxFeePerGas) gas.maxFeePerGas = feeData.maxFeePerGas * 2n
	if (feeData.maxPriorityFeePerGas) gas.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas * 2n
	const factory = new ethers.Contract(
		FACTORY,
		[
			'function owner() view returns (address)',
			'function defaultGovernanceModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
			'function setGovernanceModule(address)',
			'function setAdminStatsQueryModule(address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
		],
		wallet,
	)
	const owner = await factory.owner()
	const signerAddress = await wallet.getAddress()
	if (owner.toLowerCase() !== signerAddress.toLowerCase()) throw new Error(`Signer is not Factory owner: ${signerAddress}`)
	const previousGovernanceModule = String(await factory.defaultGovernanceModule())
	const previousAdminStatsQueryModule = String(await factory.defaultAdminStatsQueryModule())
	let moduleAddress = previousGovernanceModule
	let receipt: ethers.TransactionReceipt | null = null
	let moduleDeployTx: string | null = null
	if (process.env.SKIP_GOVERNANCE !== '1') {
		const artifact = loadArtifact()
		const module = await new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet).deploy(gas)
		await module.waitForDeployment()
		moduleAddress = await module.getAddress()
		moduleDeployTx = module.deploymentTransaction()?.hash ?? null
		const moduleCode = await provider.getCode(moduleAddress)
		if (moduleCode === '0x') throw new Error('GovernanceModule deployment has no code')
		const tx = await factory.setGovernanceModule(moduleAddress, gas)
		receipt = await tx.wait()
		if (!receipt || receipt.status !== 1) throw new Error('setGovernanceModule transaction failed')
		const bound = String(await factory.defaultGovernanceModule())
		if (bound.toLowerCase() !== moduleAddress.toLowerCase()) throw new Error(`Factory binding mismatch: ${bound}`)
	}

	const selector = ethers.id('adminManagerBatch(address[],uint256,string,uint256)').slice(0, 10)
	const liveRouter = new ethers.Contract(
		previousAdminStatsQueryModule,
		['function v5() view returns (address)', 'function referrerViews() view returns (address)'],
		provider,
	)
	const v5 = String(await liveRouter.v5())
	const referrerViews = String(await liveRouter.referrerViews())
	const routerArtifact = JSON.parse(
		fs.readFileSync(
			path.join(process.cwd(), 'artifacts/src/BeamioUserCard/AdminStatsQueryModuleV6.sol/BeamioUserCardAdminStatsQueryModuleV6.json'),
			'utf8',
		),
	) as Artifact
	const routerDeployment = await new ethers.ContractFactory(routerArtifact.abi, routerArtifact.bytecode, wallet).deploy(v5, referrerViews, gas)
	await routerDeployment.waitForDeployment()
	const routerAddress = await routerDeployment.getAddress()
	const routerTx = await factory.setAdminStatsQueryModule(routerAddress, gas)
	const routerReceipt = await routerTx.wait()
	if (!routerReceipt || routerReceipt.status !== 1) throw new Error('setAdminStatsQueryModule transaction failed')
	const routerReader = new ethers.Contract(routerAddress, ['function selectorModuleKind(bytes4) view returns (uint8)'], provider)
	const route = Number(await routerReader.selectorModuleKind(selector))
	if (route !== 3) throw new Error(`adminManagerBatch selector route is ${route}, expected governance route 3`)

	const snapshot = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		factoryOwner: owner,
		previousGovernanceModule,
		previousAdminStatsQueryModule,
		governanceModule: moduleAddress,
		adminStatsQueryModule: routerAddress,
		selector,
		selectorRoute: route,
		deployTx: receipt?.hash ?? moduleDeployTx,
		adminStatsRouterDeployTx: routerDeployment.deploymentTransaction()?.hash ?? null,
		adminStatsRouterBindTx: routerReceipt.hash,
	}
	fs.writeFileSync(
		path.join(process.cwd(), 'deployments/conet-GovernanceAdminBatch.json'),
		JSON.stringify(snapshot, null, 2) + '\n',
	)
	console.log(JSON.stringify(snapshot, null, 2))
	console.log(`Next: generate FULL Standard JSON and verify ${moduleAddress} on Blockscout v2.`)
}

main().catch((error) => {
	console.error(error)
	process.exit(1)
})
