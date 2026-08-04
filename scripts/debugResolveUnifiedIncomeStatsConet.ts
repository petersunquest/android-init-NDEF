import { network } from 'hardhat'

const PROXY = '0xc71e246DD78B37C2fABc905D340932F28F503433'
const BENEFICIARY = '0xc31043cF04CFF17a273B33F4cb851f4399e2170E'

async function main() {
	const { ethers } = await network.connect()
	const c = await ethers.getContractAt(
		[
			'function resolveUnifiedIncomeStats(address,string,uint256) view returns (tuple(address beneficiary, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) gbBeneficiary, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) cnetBeneficiary, tuple(address nodeWallet, string depinNodeIp, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) gb, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) cnet)[] nodes))',
			'function resolveNodeBundle(address,string) view returns (tuple(address beneficiary, uint256[] guardianNodeIds, string[] depinNodeIps, address[] nodeWallets, bytes[] validatorPubkeys, bool[] validatorActive, uint256 validatorNodeCount, uint256 gbMiningNodeCount, uint256 claimCount, uint256 nativeBalance, uint256 gbBalance, uint256 usdcBalance))',
			'function rewardIndexer() view returns (address)',
			'function gbToken() view returns (address)',
		],
		PROXY,
	)
	console.log('rewardIndexer', await c.rewardIndexer!())
	console.log('gbToken', await c.gbToken!())
	const bundle = await c.resolveNodeBundle!(BENEFICIARY, '')
	console.log('bundle beneficiary', bundle.beneficiary, 'nodes', bundle.guardianNodeIds?.length)
	const gb = await c.gbToken!()
	const gbC = await ethers.getContractAt(
		[
			'function balanceOf(address,uint256) view returns (uint256)',
			'function nodeTotalIssued(address) view returns (uint256)',
			'function issuedThisHourOf(address) view returns (uint256)',
		],
		gb,
	)
	console.log('nodeWallet', bundle.nodeWallets?.[0])
	console.log('balanceOf', (await gbC.balanceOf!(BENEFICIARY, 0)).toString())
	if (bundle.nodeWallets?.[0]) {
		console.log('nodeTotalIssued', (await gbC.nodeTotalIssued!(bundle.nodeWallets[0])).toString())
	}
	try {
		const stats = await c.resolveUnifiedIncomeStats!(BENEFICIARY, '', 0)
		console.log('cnet cumulative', stats.cnetBeneficiary.cumulative.toString())
		console.log('cnet hour', stats.cnetBeneficiary.hour.toString())
	} catch (e: unknown) {
		const err = e as { shortMessage?: string; message?: string; data?: string }
		console.error('resolveUnifiedIncomeStats failed:', err.shortMessage ?? err.message)
		if (err.data) console.error('data', err.data)
	}
	const STATS_LIB = '0x5DaCFBbe8C7E22A8002D24509491c8cbFeDb3739'
	const statsLib = await ethers.getContractAt(
		[
			'function resolveUnifiedFromRedeem(address,address,string,uint256,address) view returns (tuple(address beneficiary, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) gbBeneficiary, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) cnetBeneficiary, tuple(address nodeWallet, string depinNodeIp, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) gb, tuple(uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year) cnet)[] nodes))',
		],
		STATS_LIB,
	)
	try {
		const legacy = await statsLib.resolveUnifiedFromRedeem!(PROXY, BENEFICIARY, '', 0, ethers.ZeroAddress)
		console.log('legacy ok cumulative', legacy.cnetBeneficiary.cumulative.toString())
	} catch (e: unknown) {
		const err = e as { shortMessage?: string; message?: string }
		console.error('legacy resolveUnifiedFromRedeem failed:', err.shortMessage ?? err.message)
	}
}

main().catch(console.error)
