/**
 * UUPS-upgrade ValidatorDepositRedeem: treat _nativeLock 0 as unlocked (require != 2).
 *
 * Fixes settleNodeRewards / fundAndDepositValidators on legacy proxies where _nativeLock
 * was never initialized (0) while the old guard required == 1.
 *
 * Usage:
 *   npm run compile
 *   npx hardhat run scripts/upgradeValidatorDepositRedeemNativeLockFixConet.ts --network conet
 *
 * Env:
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

const LIBRARY_DEPLOY_JSON = path.join(
	process.cwd(),
	'deployments/conet-ValidatorDepositRedeem-income-periods-upgrade.json',
)

async function loadLinkedLibraries(): Promise<Record<string, string>> {
	if (!fs.existsSync(LIBRARY_DEPLOY_JSON)) {
		throw new Error(`Missing ${LIBRARY_DEPLOY_JSON}`)
	}
	const j = JSON.parse(fs.readFileSync(LIBRARY_DEPLOY_JSON, 'utf8')) as {
		libraries?: Record<string, string>
	}
	if (!j.libraries || Object.keys(j.libraries).length === 0) {
		throw new Error('No libraries in deployment json')
	}
	return j.libraries
}

async function main() {
	const { ethers } = await networkModule.connect()
	const [deployer] = await ethers.getSigners()
	const net = await ethers.provider.getNetwork()
	console.log('deployer', deployer.address)
	console.log('proxy', PROXY)

	const beforeSlot = await ethers.provider.getStorage(PROXY, EIP1967_IMPL_SLOT)
	const beforeImpl = ethers.getAddress('0x' + beforeSlot.slice(-40))
	console.log('currentImpl', beforeImpl)

	const libraries = await loadLinkedLibraries()
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

	const proxy = await ethers.getContractAt(['function upgradeToAndCall(address,bytes)'], PROXY, deployer)
	const upgradeTx = await proxy.upgradeToAndCall!(implAddr, '0x')
	console.log('upgrade tx', upgradeTx.hash)
	const upgradeRc = await upgradeTx.wait()
	if (upgradeRc?.status !== 1) throw new Error('upgradeToAndCall failed')

	const afterSlot = await ethers.provider.getStorage(PROXY, EIP1967_IMPL_SLOT)
	const afterImpl = ethers.getAddress('0x' + afterSlot.slice(-40))
	console.log('verifiedImpl', afterImpl)

	const vdr = await ethers.getContractAt(
		['function settleNodeRewards(uint256[],uint256[],bytes32[])'],
		PROXY,
	)
	const eventKey = ethers.keccak256(ethers.toUtf8Bytes('smoke-native-lock-fix'))
	await vdr.settleNodeRewards.staticCall([170n], [1_000_000_000_000_000n], [eventKey])
	console.log('smoke settleNodeRewards staticCall ok')

	const outPath = path.join(process.cwd(), 'deployments/conet-ValidatorDepositRedeem-native-lock-fix.json')
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
				upgradeTx: upgradeTx.hash,
				timestamp: new Date().toISOString(),
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
