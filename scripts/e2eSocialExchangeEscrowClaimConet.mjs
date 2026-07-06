#!/usr/bin/env node
/**
 * Escrow + Claim API e2e for CoNET social exchange (Plan A card fallback).
 *
 * Always runs: chain smoke + API precheck negative tests.
 * Full on-chain flow when env is set:
 *   CONET_E2E_OWNER_PK  — merchant card owner (approve CONET-USDC + fund escrow)
 *   CONET_E2E_USER_PK   — claimer EOA (EIP-712 social exchange claim)
 *
 * Optional:
 *   BEAMIO_API_BASE     — default https://beamio.app
 *   CONET_RPC           — default https://rpc1.conet.network
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { ethers } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, '..')
const DEPLOY_JSON = path.join(REPO_ROOT, 'deployments/conet-SocialExchangeModules.json')

const API_BASE = (process.env.BEAMIO_API_BASE ?? 'https://beamio.app').replace(/\/$/, '')
const RPC = process.env.CONET_RPC ?? 'https://rpc1.conet.network'
const CONET_USDC = '0xF9240fd613C00d5C479f1E9f1690130c5Fdc8BC3'
const CHAIN_ID = 224422n
const REWARD_VOUCHER_TOKEN_ID = 13n

function loadDeployConfig() {
	const raw = JSON.parse(fs.readFileSync(DEPLOY_JSON, 'utf8'))
	return {
		smokeCard: raw.checks?.smokeCard ?? '0xB24D242A320b8dd756572b410645FE41Cd07FC8C',
		smokeEoa: raw.checks?.smokeEoa ?? '0x4728BEeFa5b68E87a611EEC6965f5C5f9b2D5060',
		factory: raw.factory,
	}
}

async function apiPost(route, body) {
	const res = await fetch(`${API_BASE}${route}`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify(body),
	})
	const data = await res.json().catch(() => ({}))
	return { status: res.status, data }
}

async function fetchCouponSeries(card) {
	const url = `${API_BASE}/api/cardActiveIssuedCouponSeries?card=${encodeURIComponent(card)}&limit=50`
	const res = await fetch(url)
	const data = await res.json().catch(() => ({}))
	return data.items ?? []
}

function readSocialExchange(meta) {
	if (!meta || typeof meta !== 'object') return null
	const direct = meta.socialExchange
	if (direct && typeof direct === 'object' && direct.enabled !== false) return direct
	const bc = meta.beamioCoupon ?? meta
	const nested = bc?.socialExchange
	if (nested && typeof nested === 'object' && nested.enabled !== false) return nested
	return null
}

async function runPrecheckTests(card, owner) {
	console.log('\n=== API precheck (negative) ===')
	const wrongPayer = await apiPost('/api/cardFundSocialExchangeUsdcEscrow', {
		cardAddress: card,
		payerEOA: '0x0000000000000000000000000000000000000001',
		amount6: '1000000',
	})
	if (wrongPayer.status !== 400) throw new Error(`escrow wrong payer expected 400 got ${wrongPayer.status}`)
	console.log('  escrow wrong payer → 400 OK')

	const badClaim = await apiPost('/api/cardCouponOpenClaim', {
		cardAddress: card,
		couponId: 'nonexistent',
		userEOA: owner,
		tokenId: '100000000000',
		deadline: Math.floor(Date.now() / 1000) - 10,
		nonce: ethers.hexlify(ethers.randomBytes(32)),
		userSignature: '0x' + '11'.repeat(65),
	})
	if (badClaim.status !== 400) throw new Error(`claim bad payload expected 400 got ${badClaim.status}`)
	console.log('  claim invalid payload → 400 OK')
}

async function fundEscrow(provider, card, ownerWallet, amount6) {
	const owner = await ownerWallet.getAddress()
	const cardNorm = ethers.getAddress(card)
	const usdc = new ethers.Contract(
		CONET_USDC,
		[
			'function allowance(address owner, address spender) view returns (uint256)',
			'function approve(address spender, uint256 amount) returns (bool)',
			'function balanceOf(address account) view returns (uint256)',
		],
		ownerWallet,
	)
	const cardRead = new ethers.Contract(cardNorm, ['function rewardEscrowUsdc6() view returns (uint256)'], provider)
	const before = await cardRead.rewardEscrowUsdc6()
	const bal = await usdc.balanceOf(owner)
	console.log(`\n=== Escrow fund (${amount6} USDC6) ===`)
	console.log('  owner CONET-USDC balance:', bal.toString())
	if (bal < amount6) throw new Error('Owner CONET-USDC balance too low for escrow test')

	const allowance = await usdc.allowance(owner, cardNorm)
	if (allowance < amount6) {
		console.log('  approving CONET-USDC to card…')
		const tx = await usdc.approve(cardNorm, amount6)
		await tx.wait()
	}

	const apiRes = await apiPost('/api/cardFundSocialExchangeUsdcEscrow', {
		cardAddress: cardNorm,
		payerEOA: owner,
		amount6: String(amount6),
	})
	if (apiRes.status !== 200 || !apiRes.data?.success) {
		throw new Error(`escrow API failed: ${apiRes.status} ${JSON.stringify(apiRes.data)}`)
	}
	console.log('  escrow tx:', apiRes.data.hash)
	const after = await cardRead.rewardEscrowUsdc6()
	if (after < before + amount6) throw new Error(`escrow on-chain mismatch before=${before} after=${after}`)
	console.log('  rewardEscrowUsdc6:', before.toString(), '→', after.toString())
}

async function socialExchangeClaim(provider, card, userWallet, seriesRow) {
	const meta = seriesRow.metadata ?? {}
	const se = readSocialExchange(meta)
	if (!se) throw new Error('Series row has no socialExchange metadata')
	const couponId = meta.couponId ?? meta.beamioCoupon?.couponId
	const tokenId = String(seriesRow.tokenId)
	const cardNorm = ethers.getAddress(card)
	const userEOA = await userWallet.getAddress()

	const cardRead = new ethers.Contract(
		cardNorm,
		['function factoryGateway() view returns (address)'],
		provider,
	)
	const verifyingContract = ethers.getAddress(await cardRead.factoryGateway())
	const deadline = Math.floor(Date.now() / 1000) + 15 * 60
	const nonce = ethers.hexlify(ethers.randomBytes(32))
	const pointsCost = BigInt(se.pointsCost ?? se.points_cost ?? 10)
	const usdcReward6 = String(se.kind).toLowerCase() === 'usdc' ? BigInt(se.usdcReward6 ?? se.usdc_reward6 ?? 0) : 0n

	const userSignature = await userWallet.signTypedData(
		{
			name: 'BeamioUserCardFactory',
			version: '1',
			chainId: Number(CHAIN_ID),
			verifyingContract,
		},
		{
			ClaimSocialExchange: [
				{ name: 'cardAddress', type: 'address' },
				{ name: 'tokenId', type: 'uint256' },
				{ name: 'pointsCost', type: 'uint256' },
				{ name: 'usdcReward6', type: 'uint256' },
				{ name: 'deadline', type: 'uint256' },
				{ name: 'nonce', type: 'bytes32' },
			],
		},
		{
			cardAddress: cardNorm,
			tokenId: BigInt(tokenId),
			pointsCost,
			usdcReward6,
			deadline: BigInt(deadline),
			nonce,
		},
	)

	console.log(`\n=== Social exchange claim (tokenId=${tokenId}, kind=${se.kind}) ===`)
	const apiRes = await apiPost('/api/cardCouponOpenClaim', {
		cardAddress: cardNorm,
		couponId,
		userEOA,
		tokenId,
		deadline,
		nonce,
		userSignature,
		pointsCost: String(pointsCost),
		usdcReward6: String(usdcReward6),
	})
	if (apiRes.status !== 200 || !apiRes.data?.success) {
		throw new Error(`claim API failed: ${apiRes.status} ${JSON.stringify(apiRes.data)}`)
	}
	console.log('  claim tx:', apiRes.data.tx)
	return apiRes.data.tx
}

async function main() {
	const { smokeCard, smokeEoa } = loadDeployConfig()
	const provider = new ethers.JsonRpcProvider(RPC)
	const cardRead = new ethers.Contract(smokeCard, ['function owner() view returns (address)'], provider)
	const owner = ethers.getAddress(await cardRead.owner())

	console.log('=== Social exchange e2e ===')
	console.log('API:', API_BASE)
	console.log('RPC:', RPC)
	console.log('smokeCard:', smokeCard)
	console.log('card owner:', owner)
	console.log('smokeEoa:', smokeEoa)

	// Chain smoke via existing script
	console.log('\n=== Chain fallback smoke ===')
	const { spawnSync } = await import('node:child_process')
	const smoke = spawnSync('node', ['scripts/smokeSocialExchangeFallbackConet.mjs'], {
		cwd: REPO_ROOT,
		stdio: 'inherit',
	})
	if (smoke.status !== 0) process.exit(smoke.status ?? 1)

	await runPrecheckTests(smokeCard, smokeEoa)

	const ownerPk = process.env.CONET_E2E_OWNER_PK?.trim()
	const userPk = process.env.CONET_E2E_USER_PK?.trim()
	if (!ownerPk || !userPk) {
		console.log('\n=== Skipping live Escrow/Claim (set CONET_E2E_OWNER_PK + CONET_E2E_USER_PK) ===')
		const items = await fetchCouponSeries(smokeCard)
		const seRows = items.filter((row) => readSocialExchange(row.metadata))
		console.log(`  coupon series: ${items.length}, with socialExchange: ${seRows.length}`)
		if (seRows.length === 0) {
			console.log('  NOTE: smoke card has no socialExchange activity in metadata; create one in bizSite Programs first.')
		}
		console.log('\n✅ Precheck + chain smoke passed')
		return
	}

	const ownerWallet = new ethers.Wallet(ownerPk, provider)
	const userWallet = new ethers.Wallet(userPk, provider)
	if (ethers.getAddress(await ownerWallet.getAddress()) !== owner) {
		throw new Error('CONET_E2E_OWNER_PK does not match card owner')
	}

	const items = await fetchCouponSeries(smokeCard)
	const seRow = items.find((row) => readSocialExchange(row.metadata))
	if (!seRow) throw new Error('No socialExchange coupon on smoke card — create activity in bizSite first')

	const se = readSocialExchange(seRow.metadata)
	const escrowAmount =
		se && String(se.kind).toLowerCase() === 'usdc'
			? BigInt(se.usdcReward6 ?? se.usdc_reward6 ?? 0) * 2n
			: 1_000_000n

	await fundEscrow(provider, smokeCard, ownerWallet, escrowAmount)
	await socialExchangeClaim(provider, smokeCard, userWallet, seRow)
	console.log('\n✅ Escrow + Claim e2e passed')
}

main().catch((e) => {
	console.error('\n❌ e2e failed:', e?.message ?? e)
	process.exit(1)
})
