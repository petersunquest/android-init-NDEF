/**
 * UUPS-upgrade ValidatorDepositRedeem: CL settle period buckets + StatsLib GB/CNET merge.
 *
 * After upgrade:
 *   1. Deploy new GBDepinAirdrop (period views) — deployGBDepinAirdropToConet.ts
 *   2. redeem.setGbDepinAirdrop(newAirdrop) — included in deploy script when VDR_ADDRESS set
 *
 * Usage:
 *   npm run compile
 *   npx hardhat run scripts/upgradeValidatorDepositRedeemIncomePeriodsConet.ts --network conet
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   VDR_PROXY — default 0xc71e246DD78B37C2fABc905D340932F28F503433
 *   DRY_RUN=1 — deploy impl only, skip upgradeToAndCall
 */
import fs from 'fs'
import path from 'path'
import { network as networkModule } from 'hardhat'

const PROXY =
	process.env.VDR_PROXY?.trim() || '0xc71e246DD78B37C2fABc905D340932F28F503433'
const EIP1967_IMPL_SLOT =
	'0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

const VDR_LIBRARY_NAMES = [
	'ValidatorDepositRedeemAllocLib',
	'ValidatorDepositRedeemBundleLib',
	'ValidatorDepositRedeemDepositLib',
	'ValidatorDepositRedeemExitLib',
	'ValidatorDepositRedeemReleaseLib',
	'ValidatorDepositRedeemRewardLib',
	'ValidatorDepositRedeemStatsLib',
	'ValidatorDepositRedeemTransferLib',
] as const

async function deployValidatorDepositRedeemLibraries(
	ethers: Awaited<ReturnType<typeof networkModule.connect>>['ethers'],
) {
	const libraries: Record<string, string> = {}
	for (const name of VDR_LIBRARY_NAMES) {
		console.log(`deploying library ${name}…`)
		const Lib = await ethers.getContractFactory(name)
		const lib = await Lib.deploy()
		await lib.waitForDeployment()
		libraries[name] = await lib.getAddress()
		console.log('  →', libraries[name])
	}
	return libraries
}

async function main() {
	const { ethers } = await networkModule.connect()
	const [deployer] = await ethers.getSigners()
	const net = await ethers.provider.getNetwork()
	console.log('deployer', deployer.address)
	console.log('proxy', PROXY)
	console.log('chainId', net.chainId.toString())

	const beforeSlot = await ethers.provider.getStorage(PROXY, EIP1967_IMPL_SLOT)
	const beforeImpl = ethers.getAddress('0x' + beforeSlot.slice(-40))
	console.log('currentImpl', beforeImpl)

	const libraries = await deployValidatorDepositRedeemLibraries(ethers)

	console.log('deploying ValidatorDepositRedeem implementation (linked libraries)…')
	const statsLibAddr = libraries.ValidatorDepositRedeemStatsLib
	const Factory = await ethers.getContractFactory('ValidatorDepositRedeem', { libraries })
	const impl = await Factory.deploy(statsLibAddr)
	await impl.waitForDeployment()
	const implAddr = await impl.getAddress()
	console.log('newImpl', implAddr)

	if (process.env.DRY_RUN === '1') {
		console.log('DRY_RUN=1 — skip upgradeToAndCall')
		return
	}

	const proxy = await ethers.getContractAt(
		['function upgradeToAndCall(address,bytes)'],
		PROXY,
		deployer,
	)
	const tx = await proxy.upgradeToAndCall!(implAddr, '0x')
	console.log('upgrade tx', tx.hash)
	const rc = await tx.wait()
	if (rc?.status !== 1) throw new Error('upgradeToAndCall failed')

	const afterSlot = await ethers.provider.getStorage(PROXY, EIP1967_IMPL_SLOT)
	const afterImpl = ethers.getAddress('0x' + afterSlot.slice(-40))
	console.log('verifiedImpl', afterImpl)

	const vdr = await ethers.getContractAt(
		[
			'function resolveUnifiedIncomeStats(address,string,uint256) view returns (tuple(address beneficiary, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) gbBeneficiary, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) cnetBeneficiary, tuple(address nodeWallet, string depinNodeIp, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) gb, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) cnet)[] nodes))',
		],
		PROXY,
	)
	const sample = await vdr.resolveUnifiedIncomeStats!('0xc31043cF04CFF17a273B33F4cb851f4399e2170E', '', 0)
	const cnet = sample.cnetBeneficiary ?? sample[2]
	console.log('smoke resolveUnifiedIncomeStats cnet cumulative', cnet?.cumulative?.toString?.() ?? cnet?.[0]?.toString?.())

	const outPath = path.join(process.cwd(), 'deployments/conet-ValidatorDepositRedeem-income-periods-upgrade.json')
	fs.writeFileSync(
		outPath,
		JSON.stringify(
			{
				network: 'conet',
				chainId: Number(net.chainId),
				proxy: PROXY,
				previousImplementation: beforeImpl,
				implementation: afterImpl,
				libraries,
				upgradeTx: tx.hash,
				timestamp: new Date().toISOString(),
				nextSteps: [
					'Deploy new GBDepinAirdrop with period views (deployGBDepinAirdropToConet.ts)',
					'Call setGbDepinAirdrop(new) on proxy',
					'Rebuild x402sdk + restart conet-beamio-api',
				],
			},
			null,
			2,
		),
	)
	console.log('wrote', outPath)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
