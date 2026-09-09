import { fetchMyPosAddresses, fetchUIDAssets, fetchWalletAssetsForRead } from '@/api/beamioApi'
import type { UIDAssetsResult } from '@/types/pos'
import { memberNoFromCard, readBalanceHeroAmount, readBalancePrimaryCard } from '@/utils/readBalanceAssets'
import { shortAddress } from '@/utils/display'

export type ChargePendingCustomer =
	| { kind: 'nfc'; uid: string; sun: { e: string; c: string; m: string } }
	| { kind: 'qr'; payload: Record<string, unknown> }

export type ChargeAdminCardBalanceRow = {
	cardAddress: string
	cardName: string
	cardCurrency: string
	/** Store credit (#0) in card currency. `null` = untrusted this round. */
	storeCredit: number | null
	/** Reward PT (#13) human amount. `null` = untrusted. */
	rewardPts: number | null
	memberNo: string
	trusted: boolean
}

function isLikelyAddress(raw: string): boolean {
	const t = raw.trim()
	return t.startsWith('0x') && t.length >= 42
}

function cardKey(raw: string): string {
	return raw.trim().toLowerCase()
}

function displayProgramCardName(name: string, address: string): string {
	const n = name.trim()
	if (
		!n ||
		/beamio user card/i.test(n) ||
		n.toLowerCase() === 'asset card' ||
		n.toLowerCase() === 'merchant program card' ||
		n.toLowerCase() === 'beamiousercard'
	) {
		return `Program card ${shortAddress(address)}`
	}
	return n.replace(/\s+CARD$/i, '').trim() || n
}

export function sameChargeCurrency(a: string, b: string): boolean {
	return a.trim().toUpperCase() === b.trim().toUpperCase()
}

/** Deduped POS admin program cards; active card first. */
export function listPosAdminMerchantCards(
	bindings: { cardAddress: string }[],
	activeCard: string | null | undefined,
): string[] {
	const out: string[] = []
	const seen = new Set<string>()
	const add = (raw: string) => {
		const t = raw.trim()
		if (!isLikelyAddress(t)) return
		const k = cardKey(t)
		if (seen.has(k)) return
		seen.add(k)
		out.push(t)
	}
	add(activeCard ?? '')
	for (const row of bindings) add(row.cardAddress)
	return out
}

/**
 * After scan: use session bindings immediately so Charge is not blocked on a
 * second `myPosAddresses` round-trip. Only fetch when the session list is empty.
 * Fetch failure keeps the active card (if any).
 */
export async function resolvePosAdminMerchantCards(params: {
	wallet: string
	activeCard: string
	bindings: { cardAddress: string }[]
}): Promise<string[]> {
	const fromBindings = listPosAdminMerchantCards(params.bindings, params.activeCard)
	if (fromBindings.length > 0) return fromBindings
	const items = await fetchMyPosAddresses(params.wallet)
	if (items === null) return listPosAdminMerchantCards([], params.activeCard)
	return listPosAdminMerchantCards(items, params.activeCard)
}

export function qrChargeCustomerWallet(payload: Record<string, unknown>): string {
	const account = typeof payload.account === 'string' ? payload.account.trim() : ''
	if (isLikelyAddress(account)) return account
	const wallet = typeof payload.wallet === 'string' ? payload.wallet.trim() : ''
	if (isLikelyAddress(wallet)) return wallet
	return ''
}

function rowFromTrustedAssets(cardAddress: string, assets: UIDAssetsResult): ChargeAdminCardBalanceRow {
	const primary = readBalancePrimaryCard(assets, cardAddress)
	const name = displayProgramCardName(primary?.cardName ?? assets.cards?.[0]?.cardName ?? '', cardAddress)
	const currency = (primary?.cardCurrency ?? assets.cardCurrency ?? '').trim() || 'CAD'
	const storeCredit = readBalanceHeroAmount(primary, assets)
	const rewardRaw = primary?.chargeRewardPoints6?.trim() ?? assets.chargeRewardPoints6?.trim() ?? '0'
	const reward6 = Number(rewardRaw)
	const rewardPts = Number.isFinite(reward6) ? reward6 / 1_000_000 : 0
	return {
		cardAddress,
		cardName: name,
		cardCurrency: currency,
		storeCredit,
		rewardPts,
		memberNo: memberNoFromCard(primary),
		trusted: true,
	}
}

function untrustedRow(cardAddress: string): ChargeAdminCardBalanceRow {
	return {
		cardAddress,
		cardName: displayProgramCardName('', cardAddress),
		cardCurrency: '',
		storeCredit: null,
		rewardPts: null,
		memberNo: '',
		trusted: false,
	}
}

async function fetchOneAdminCardBalance(
	cardAddress: string,
	customer: ChargePendingCustomer,
): Promise<ChargeAdminCardBalanceRow> {
	const assets =
		customer.kind === 'nfc'
			? await fetchUIDAssets({
					uid: customer.uid,
					merchantInfraCard: cardAddress,
					sun: customer.sun,
				})
			: await fetchWalletAssetsForRead({
					wallet: qrChargeCustomerWallet(customer.payload),
					merchantInfraCard: cardAddress,
				})
	if (!assets || assets.ok === false) return untrustedRow(cardAddress)
	return rowFromTrustedAssets(cardAddress, assets)
}

/** One request per POS admin card. A failed card stays untrusted — never written as 0. */
export async function fetchChargeAdminCardBalances(params: {
	cards: string[]
	customer: ChargePendingCustomer
}): Promise<ChargeAdminCardBalanceRow[]> {
	if (params.customer.kind === 'qr' && !qrChargeCustomerWallet(params.customer.payload)) {
		return params.cards.map(untrustedRow)
	}
	return Promise.all(params.cards.map((card) => fetchOneAdminCardBalance(card, params.customer)))
}

export function pickDefaultChargeAdminCard(
	rows: ChargeAdminCardBalanceRow[],
	billCurrency: string,
	preferredCard?: string,
): string {
	const preferred = preferredCard?.trim().toLowerCase() ?? ''
	const usable = rows.filter(
		(row) => row.trusted && sameChargeCurrency(row.cardCurrency, billCurrency),
	)
	if (preferred) {
		const hit = usable.find((row) => cardKey(row.cardAddress) === preferred)
		if (hit) return hit.cardAddress
	}
	return usable[0]?.cardAddress ?? ''
}
