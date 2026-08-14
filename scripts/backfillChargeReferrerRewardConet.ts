/**
 * One-shot backfill: mint Charge Referrer #1 for a past charge that missed UpdateLib path.
 *
 * Uses Plan A: settle admin → relayer AA execute(card, recordChargeReferrerReward).
 *
 * Usage:
 *   npx tsx scripts/backfillChargeReferrerRewardConet.ts
 *
 * Env:
 *   CARD USER_EOA AMOUNT_FIAT6 REFERRER_AA CONET_RPC_URL
 */
import { ethers } from 'ethers'

const CARD = process.env.CARD || '0xafE482D2612327a0D723544B9fB713C514a793a2'
const USER_EOA = process.env.USER_EOA || '0x1c07848A73a99A18B0af6930Dac104485DD48EfE'
const AMOUNT_FIAT6 = BigInt(process.env.AMOUNT_FIAT6 || '100000000') // 100.00
const REFERRER_AA = process.env.REFERRER_AA || '0x2A6401E54aaF83918793bC72F3cdF3eA24CD7bAF'
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'

async function main() {
	const { initSettleContractPool, Settle_ContractPool } = await import(
		'../src/x402sdk/src/settleContractPool.js'
	)
	const { relayUserCardCallViaEntryPoint, checkBusinessRelayTxSuccessful } = await import(
		'../src/x402sdk/src/MemberCard.js'
	)
	const { CHARGE_REWARD_V2_IFACE } = await import(
		'../src/x402sdk/src/userCumulativeStatRewardPool.js'
	)

	initSettleContractPool()
	const SC = Settle_ContractPool[0]
	if (!SC) throw new Error('Settle_ContractPool empty — check ~/.master.json')

	const card = ethers.getAddress(CARD)
	const user = ethers.getAddress(USER_EOA)
	const provider = new ethers.JsonRpcProvider(RPC)
	const erc1155 = new ethers.Contract(
		card,
		['function balanceOf(address,uint256) view returns (uint256)'],
		provider,
	)
	const before = (await erc1155.balanceOf(REFERRER_AA, 1n)) as bigint
	console.log(`[backfill] referrer AA #1 before=${before}`)

	const cardCallData = CHARGE_REWARD_V2_IFACE.encodeFunctionData('recordChargeReferrerReward', [
		user,
		AMOUNT_FIAT6,
	])
	console.log(`[backfill] card=${card} user=${user} amountFiat6=${AMOUNT_FIAT6}`)
	const tx = await relayUserCardCallViaEntryPoint({
		SC,
		chain: 'conet',
		cardAddress: card,
		cardCallData,
		logTag: 'backfillChargeReferrerReward',
	})
	console.log(`[backfill] submitted ${tx.hash}`)
	const receipt = await tx.wait()
	const check = checkBusinessRelayTxSuccessful(receipt ?? undefined, {
		logTag: 'backfillChargeReferrerReward',
	})
	if (!check.ok) throw new Error(check.reason ?? 'UserOp failed')
	const after = (await erc1155.balanceOf(REFERRER_AA, 1n)) as bigint
	console.log(`[backfill] referrer AA #1 after=${after} delta=${after - before}`)
	console.log('[backfill] done')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
