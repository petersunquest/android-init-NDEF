/**
 * CoNET complete set: Top-up #13 paid-base pack (TopupMintAmountCodec).
 *
 * 1) ChargeRewardModuleV2 + AdminStats V6 (`upgradeChargeRewardTopupRatioConet.ts`)
 * 2) UserCard beacon → VERSION 17 (`upgradeUserCardBeaconConet.ts`)
 *
 * Then Blockscout verify (same task):
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardChargeRewardModuleV2 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV6 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCard --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardGatewayMintLib --full
 *   CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyChargeRewardTopupRatioConet.ts
 *   CONET_VERIFY_ONLY=AdminStatsQueryModuleV6 CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyMembershipFeeModulesConet.ts
 *   CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyUserCardBeaconConet.ts
 *
 * Usage:
 *   npm run clean && npm run compile
 *   npx tsx scripts/upgradeTopupMintPackConet.ts
 */
import { spawnSync } from 'child_process'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.join(__dirname, '..')

function run(scriptRel: string): void {
	const script = path.join(root, scriptRel)
	console.log(`\n======== ${scriptRel} ========\n`)
	const r = spawnSync('npx', ['tsx', script], {
		cwd: root,
		stdio: 'inherit',
		env: process.env,
	})
	if (r.status !== 0) {
		throw new Error(`${scriptRel} failed with status ${r.status}`)
	}
}

async function main(): Promise<void> {
	run('scripts/upgradeChargeRewardTopupRatioConet.ts')
	run('scripts/upgradeUserCardBeaconConet.ts')
	console.log('\n[upgradeTopupMintPack] both upgrades OK — run export + Blockscout verify next\n')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
