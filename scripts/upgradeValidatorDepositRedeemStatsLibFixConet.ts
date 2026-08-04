/**
 * Hotfix: point resolveUnifiedIncomeStats at StatsLib with try/catch around legacy gbDepinAirdrop.
 * Reuses already-deployed libraries from the income-periods upgrade (no full library redeploy).
 */
import fs from 'fs'
import path from 'path'
import { network as networkModule } from 'hardhat'

const PROXY =
	process.env.VDR_PROXY?.trim() || '0xc71e246DD78B37C2fABc905D340932F28F503433'
const EIP1967_IMPL_SLOT =
	'0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

/** Libraries from upgrade tx 0x83866845… (2026-08-01), StatsLib replaced with try/catch build. */
const LIBRARIES: Record<string, string> = {
	ValidatorDepositRedeemAllocLib: '0xB94bcB09BB536aFF22553ef565BA1a4a72Fb2ADB',
	ValidatorDepositRedeemBundleLib: '0x8E7e69b20E7ab8f9A674CCC6b6EEA669C2FEdC68',
	ValidatorDepositRedeemDepositLib: '0x58c3220792216C9713389091118c7962B5192198',
	ValidatorDepositRedeemExitLib: '0x2E07F8b0a99136F2D8497eBDC774ED66E719CAC0',
	ValidatorDepositRedeemReleaseLib: '0x1cB79435B5c8D118AA3d22C04833aef9E7a400d1',
	ValidatorDepositRedeemRewardLib: '0x22fBeEb15976fb18ce0c1c8aA971bbF6C17560d5',
	ValidatorDepositRedeemStatsLib: '0x4f86C913efe79686D029374B2E782bf0a4fa3676',
	ValidatorDepositRedeemTransferLib: '0xc3E1A0F07124cc2f3dBb892165835051B2d85FbE',
}

const SAMPLE_BEN = '0xc31043cF04CFF17a273B33F4cb851f4399e2170E'

async function main() {
	const { ethers } = await networkModule.connect()
	const [deployer] = await ethers.getSigners()
	const net = await ethers.provider.getNetwork()
	console.log('deployer', deployer.address)
	console.log('proxy', PROXY)

	const beforeSlot = await ethers.provider.getStorage(PROXY, EIP1967_IMPL_SLOT)
	const beforeImpl = ethers.getAddress('0x' + beforeSlot.slice(-40))
	console.log('currentImpl', beforeImpl)

	const statsLibAddr = LIBRARIES.ValidatorDepositRedeemStatsLib
	const Factory = await ethers.getContractFactory('ValidatorDepositRedeem', { libraries: LIBRARIES })
	const impl = await Factory.deploy(statsLibAddr)
	await impl.waitForDeployment()
	const implAddr = await impl.getAddress()
	console.log('newImpl', implAddr, 'unifiedStatsLib', statsLibAddr)

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
	console.log('verifiedImpl', ethers.getAddress('0x' + afterSlot.slice(-40)))

	const vdr = await ethers.getContractAt(
		[
			'function resolveUnifiedIncomeStats(address,string,uint256) view returns (tuple(address beneficiary, tuple(uint256,uint256,uint256,uint256,uint256,uint256) gbBeneficiary, tuple(uint256,uint256,uint256,uint256,uint256,uint256) cnetBeneficiary, tuple(address nodeWallet, string depinNodeIp, tuple(uint256,uint256,uint256,uint256,uint256,uint256) gb, tuple(uint256,uint256,uint256,uint256,uint256,uint256) cnet)[] nodes))',
		],
		PROXY,
	)
	const sample = await vdr.resolveUnifiedIncomeStats!(SAMPLE_BEN, '', 0)
	console.log('smoke beneficiary', sample.beneficiary ?? sample[0])
	console.log('smoke nodes', (sample.nodes ?? sample[3])?.length ?? 0)

	const outPath = path.join(process.cwd(), 'deployments/conet-ValidatorDepositRedeem-income-periods-upgrade.json')
	fs.writeFileSync(
		outPath,
		JSON.stringify(
			{
				network: 'conet',
				chainId: Number(net.chainId),
				proxy: PROXY,
				previousImplementation: beforeImpl,
				implementation: implAddr,
				libraries: LIBRARIES,
				upgradeTx: tx.hash,
				timestamp: new Date().toISOString(),
				notes: [
					'resolveUnifiedIncomeStats uses external CALL to immutable StatsLib (not library delegatecall)',
					'StatsLib try/catch skips legacy gbDepinAirdrop without paidGbSummaryOf',
				],
				nextSteps: [
					'Deploy new GBDepinAirdrop (deployGBDepinAirdropToConet.ts) + setGbDepinAirdrop(new)',
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
