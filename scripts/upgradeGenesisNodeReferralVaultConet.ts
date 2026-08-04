/**
 * Deploy new GenesisNodeReferralVaultV1 implementation and UUPS-upgrade the proxy.
 *
 * Proxy (canonical): 0x051b65E5711E6E74bC236Fe220dcA7021841855C
 * Adds setL1Ratio / setL1RatioFor so L0 can update Downstream L1 share on-chain.
 *
 * Usage:
 *   npx tsx scripts/upgradeGenesisNodeReferralVaultConet.ts
 */
import fs from 'fs'
import path from 'path'
import { homedir } from 'os'
import { ethers } from 'ethers'

const PROXY = '0x051b65E5711E6E74bC236Fe220dcA7021841855C'
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const CHAIN_ID = 224422
const EIP1967_IMPL_SLOT =
	'0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

function loadOwnerKey(): string {
	const masterPath = path.join(homedir(), '.master.json')
	const master = JSON.parse(fs.readFileSync(masterPath, 'utf-8')) as {
		settle_contractAdmin?: string[]
		beamio_Admins?: string[]
	}
	const keys = [...(master.settle_contractAdmin ?? []), ...(master.beamio_Admins ?? [])]
	const ownerWanted = '0x87caed4e51c36a2c2ece3aaf4ddac9693d2405e1'.toLowerCase()
	for (const raw of keys) {
		const key = raw.startsWith('0x') ? raw : `0x${raw}`
		try {
			if (new ethers.Wallet(key).address.toLowerCase() === ownerWanted) return key
		} catch {
			/* skip */
		}
	}
	throw new Error('Owner key for 0x87cAeD… not found in ~/.master.json')
}

async function main() {
	const artifactPath = path.join(
		process.cwd(),
		'artifacts/src/mainnet/GenesisNodeReferralVaultV1.sol/GenesisNodeReferralVaultV1.json',
	)
	if (!fs.existsSync(artifactPath)) {
		throw new Error('Missing artifact — run: npx hardhat compile')
	}
	const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf-8')) as {
		abi: ethers.InterfaceAbi
		bytecode: string
	}

	const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID)
	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	console.log('deployer', wallet.address)
	console.log('rpc', RPC)

	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) {
		throw new Error(`Unexpected chainId ${net.chainId}`)
	}

	const proxyAsOwnable = new ethers.Contract(
		PROXY,
		['function owner() view returns (address)', 'function upgradeToAndCall(address,bytes)'],
		wallet,
	)
	const owner = await proxyAsOwnable.owner!()
	if (ethers.getAddress(owner) !== wallet.address) {
		throw new Error(`Signer ${wallet.address} is not proxy owner ${owner}`)
	}

	const beforeSlot = await provider.getStorage(PROXY, EIP1967_IMPL_SLOT)
	const beforeImpl = ethers.getAddress('0x' + beforeSlot.slice(-40))
	console.log('currentImpl', beforeImpl)

	const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet)
	console.log('deploying implementation…')
	const impl = await factory.deploy()
	await impl.waitForDeployment()
	const implAddress = await impl.getAddress()
	const deployTx = impl.deploymentTransaction()
	console.log('newImpl', implAddress, 'deployTx', deployTx?.hash)

	const upgradeTx = await proxyAsOwnable.upgradeToAndCall!(implAddress, '0x')
	console.log('upgradeTx', upgradeTx.hash)
	const receipt = await upgradeTx.wait()
	if (receipt?.status !== 1) throw new Error('upgradeToAndCall failed')

	const afterSlot = await provider.getStorage(PROXY, EIP1967_IMPL_SLOT)
	const afterImpl = ethers.getAddress('0x' + afterSlot.slice(-40))
	if (afterImpl !== ethers.getAddress(implAddress)) {
		throw new Error(`impl slot mismatch: ${afterImpl} !== ${implAddress}`)
	}

	const vault = new ethers.Contract(
		PROXY,
		[
			'function SET_L1_RATIO_TYPEHASH() view returns (bytes32)',
			'function setL1Ratio(address,uint256)',
		],
		provider,
	)
	const typehash = await vault.SET_L1_RATIO_TYPEHASH!()
	console.log('SET_L1_RATIO_TYPEHASH', typehash)

	const code = await provider.getCode(implAddress)
	const out = {
		network: 'conet',
		chainId: CHAIN_ID,
		proxy: PROXY,
		implementation: implAddress,
		previousImplementation: beforeImpl,
		deployTx: deployTx?.hash ?? null,
		upgradeTx: upgradeTx.hash,
		upgradeBlock: receipt?.blockNumber ?? null,
		SET_L1_RATIO_TYPEHASH: typehash,
		bytecodeTail: code.slice(-24),
		updatedAt: new Date().toISOString(),
	}
	const outPath = path.join(process.cwd(), 'deployments/conet-GenesisNodeReferralVault.json')
	fs.mkdirSync(path.dirname(outPath), { recursive: true })
	fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n')
	console.log('wrote', outPath)
	console.log('next: verify impl on Blockscout + update CONET_GENESIS_NODE_REFERRAL_VAULT_IMPL')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
