import { Interface } from 'ethers'
import { ACCOUNT_REGISTRY, BEAMIO_API, CONET_RPC } from '@/constants'
import type { PosLedgerSnapshot } from '@/utils/posLedgerMetrics'
import { parsePosLedgerResponse } from '@/utils/posLedgerMetrics'
import {
	parseMerchantActiveIssuedCouponRow,
	type MerchantActiveIssuedCoupon,
} from '@/utils/couponMetadata'
import type {
	CardAdminInfoResponse,
	MyPosAddressResponse,
	TerminalProfile,
	UIDAssetsResult,
} from '@/types/pos'
import { parseUIDAssetsResponse } from '@/utils/readBalanceAssets'
import { parseMetadataTierRows, type MetadataTierRow } from '@/utils/beamioPaymentRouting'
import { isPlausibleEvmAddress } from '@/utils/evmAddress'
import { parsePointSystemEnabledFromMetadata } from '@/utils/pointSystemMetadata'

const registryIface = new Interface([
	'function isAccountNameAvailable(string name) view returns (bool)',
])

function parseProfiles(body: unknown): TerminalProfile[] {
	if (!body || typeof body !== 'object') return []
	const results = (body as { results?: unknown }).results
	if (!Array.isArray(results)) return []
	return results
		.map((row) => {
			if (!row || typeof row !== 'object') return null
			const o = row as Record<string, unknown>
			return {
				accountName: String(o.username ?? o.accountName ?? '').trim() || undefined,
				username: String(o.username ?? '').trim() || undefined,
				first_name: String(o.first_name ?? o.firstName ?? '').trim() || undefined,
				last_name: String(o.last_name ?? o.lastName ?? '').trim() || undefined,
				image: String(o.image ?? '').trim() || undefined,
				address: String(o.address ?? '').trim() || undefined,
			} satisfies TerminalProfile
		})
		.filter(Boolean) as TerminalProfile[]
}

export async function searchUsersByCardOwnerOrAdmin(
	keyword: string,
	extraCardAddresses: string[] = [],
): Promise<TerminalProfile[] | null> {
	const kw = keyword.trim().toLowerCase()
	if (kw.length < 2) return []
	try {
		const params = new URLSearchParams({ keyward: kw })
		const extra = extraCardAddresses
			.map((a) => a.trim())
			.filter((a) => a.startsWith('0x') && a.length >= 42)
		if (extra.length) params.set('extraCardAddresses', extra.join(','))
		const res = await fetch(`${BEAMIO_API}/api/search-users-by-card-owner-or-admin?${params}`)
		if (!res.ok) return null
		const json = await res.json()
		return parseProfiles(json)
	} catch {
		return null
	}
}

export async function searchUsers(keyword: string): Promise<TerminalProfile[] | null> {
	const kw = keyword.trim().toLowerCase()
	if (kw.length < 2) return []
	try {
		const params = new URLSearchParams({ keyward: kw })
		const res = await fetch(`${BEAMIO_API}/api/search-users?${params}`)
		if (!res.ok) return null
		const json = await res.json()
		return parseProfiles(json)
	} catch {
		return null
	}
}

export async function isBeamioAccountNameAvailable(normalizedHandle: string): Promise<boolean | null> {
	const name = normalizedHandle.trim()
	if (!name || !/^[a-zA-Z0-9_.]{3,20}$/.test(name)) return false
	try {
		const data = registryIface.encodeFunctionData('isAccountNameAvailable', [name])
		const res = await fetch(CONET_RPC, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				jsonrpc: '2.0',
				method: 'eth_call',
				params: [{ to: ACCOUNT_REGISTRY, data }, 'latest'],
				id: 1,
			}),
		})
		if (!res.ok) return null
		const json = await res.json()
		if (json.error) return null
		const hex = String(json.result ?? '')
		if (!hex || hex === '0x') return null
		const decoded = registryIface.decodeFunctionResult('isAccountNameAvailable', hex)
		return Boolean(decoded[0])
	} catch {
		return null
	}
}

export async function addUser(params: {
	accountName: string
	wallet: string
	signMessage: string
	recover?: Array<{ hash: string; encrypto: string }>
}): Promise<{ ok: boolean; error?: string }> {
	try {
		const res = await fetch(`${BEAMIO_API}/api/addUser`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				accountName: params.accountName,
				wallet: params.wallet,
				signMessage: params.signMessage,
				recover: params.recover ?? [],
			}),
		})
		const json = await res.json().catch(() => ({}))
		if (!res.ok) {
			return { ok: false, error: String((json as { error?: string }).error ?? `HTTP ${res.status}`) }
		}
		return { ok: true }
	} catch (e) {
		return { ok: false, error: e instanceof Error ? e.message : 'Network error' }
	}
}

export async function fetchMyPosAddress(wallet: string): Promise<MyPosAddressResponse | null> {
	try {
		const params = new URLSearchParams({ wallet })
		const res = await fetch(`${BEAMIO_API}/api/myPosAddress?${params}`)
		if (!res.ok) return null
		return (await res.json()) as MyPosAddressResponse
	} catch {
		return null
	}
}

export async function fetchPosLedger(eoa: string, infraCard: string): Promise<PosLedgerSnapshot | null> {
	try {
		const params = new URLSearchParams({ eoa, infraCard })
		const res = await fetch(`${BEAMIO_API}/api/posLedger?${params}`)
		if (!res.ok) return null
		const json = await res.json()
		return parsePosLedgerResponse(json)
	} catch {
		return null
	}
}

export async function fetchBUnitBalance(address: string): Promise<number | null> {
	try {
		const params = new URLSearchParams({ address })
		const res = await fetch(`${BEAMIO_API}/api/getBUnitBalance?${params}`)
		if (!res.ok) return null
		const json = (await res.json()) as {
			ok?: boolean
			balance?: number | string
			balance6?: string
			total?: number | string
			free?: number | string
		}
		if (json.total != null) {
			const n = Number(json.total)
			return Number.isFinite(n) ? n : null
		}
		if (json.balance != null) {
			const n = Number(json.balance)
			return Number.isFinite(n) ? n : null
		}
		if (json.balance6 != null) {
			const n = Number(json.balance6) / 1e6
			return Number.isFinite(n) ? n : null
		}
		return null
	} catch {
		return null
	}
}

export async function fetchCardAdminInfo(
	cardAddress: string,
	wallet: string,
): Promise<CardAdminInfoResponse | null> {
	try {
		const params = new URLSearchParams({ cardAddress, wallet })
		const res = await fetch(`${BEAMIO_API}/api/getCardAdminInfo?${params}`)
		if (!res.ok) return null
		return (await res.json()) as CardAdminInfoResponse
	} catch {
		return null
	}
}

export async function fetchWalletAssets(wallet: string, merchantInfraCard?: string): Promise<{
	hasAAAccount?: boolean
	cardName?: string
} | null> {
	const infra = merchantInfraCard?.trim() ?? ''
	if (infra) {
		const root = await fetchCardMetadataRoot(infra)
		const meta = root?.metadata
		if (meta && typeof meta === 'object') {
			const o = meta as { name?: unknown; cardName?: unknown; title?: unknown }
			const cardName =
				String(o.name ?? '').trim() ||
				String(o.cardName ?? '').trim() ||
				String(o.title ?? '').trim()
			return cardName ? { cardName } : {}
		}
		return {}
	}
	try {
		const params = new URLSearchParams({ wallet, cardsScope: 'merchantInfraOnly' })
		const res = await fetch(`${BEAMIO_API}/api/getWalletAssets?${params}`)
		if (!res.ok) return null
		const json = (await res.json()) as {
			ok?: boolean
			hasAAAccount?: boolean
			cards?: Array<{ cardName?: string; cardAddress?: string }>
		}
		const card = json.cards?.[0]
		return {
			hasAAAccount: json.hasAAAccount,
			cardName: card?.cardName,
		}
	} catch {
		return null
	}
}

export async function fetchActiveCoupons(
	card: string,
): Promise<MerchantActiveIssuedCoupon[] | null> {
	try {
		const params = new URLSearchParams({ card, limit: '50' })
		const res = await fetch(`${BEAMIO_API}/api/cardActiveIssuedCouponSeries?${params}`)
		if (!res.ok) return null
		const json = (await res.json()) as { items?: unknown[] }
		if (!Array.isArray(json.items)) return []
		return json.items
			.map(parseMerchantActiveIssuedCouponRow)
			.filter(Boolean) as MerchantActiveIssuedCoupon[]
	} catch {
		return null
	}
}

export async function fetchCardMetadataPointSystem(cardAddress: string): Promise<boolean | null> {
	try {
		const root = await fetchCardMetadataRoot(cardAddress)
		if (!root?.metadata || typeof root.metadata !== 'object') return null
		return parsePointSystemEnabledFromMetadata(root.metadata as Record<string, unknown>)
	} catch {
		return null
	}
}

export async function fetchCardMetadataRoot(
	cardAddress: string,
): Promise<{ metadata?: Record<string, unknown> } | null> {
	try {
		const params = new URLSearchParams({ cardAddress })
		const res = await fetch(`${BEAMIO_API}/api/cardMetadata?${params}`)
		if (!res.ok) return null
		return (await res.json()) as { metadata?: Record<string, unknown> }
	} catch {
		return null
	}
}

/** iOS `fetchCardMetadataTiersBundle` — `/api/cardMetadata` → `metadata.tiers`. */
export async function fetchCardMetadataTiersBundle(
	cardAddress: string | undefined,
): Promise<{ rows: MetadataTierRow[]; fromApi: boolean }> {
	const addr = cardAddress?.trim() ?? ''
	if (!addr) return { rows: [], fromApi: false }
	const resp = await fetchCardMetadataRoot(addr)
	const tiersArr = (resp?.metadata as { tiers?: unknown[] } | undefined)?.tiers
	if (!Array.isArray(tiersArr) || tiersArr.length === 0) return { rows: [], fromApi: false }
	const rows = parseMetadataTierRows(tiersArr)
	return { rows, fromApi: rows.length > 0 }
}

export async function fetchCardCurrencyCode(cardAddress: string): Promise<string | null> {
	try {
		const root = await fetchCardMetadataRoot(cardAddress)
		const meta = root?.metadata
		if (meta && typeof meta === 'object') {
			const ccy = String((meta as { currency?: string }).currency ?? '').trim()
			if (ccy) return ccy.toUpperCase()
		}
		return null
	} catch {
		return null
	}
}

export async function fetchCardOwner(
	cardAddress: string,
	wallet: string,
): Promise<string | null> {
	const info = await fetchCardAdminInfo(cardAddress, wallet)
	return info?.owner?.trim() || null
}

export interface NfcTopupPrepareResult {
	cardAddr?: string
	data?: string
	deadline?: number
	nonce?: string
	wallet?: string
	factoryGateway?: string
	error?: string
}

export async function nfcTopupPrepare(body: {
	uid?: string
	wallet?: string
	beamioTag?: string
	amount: string
	currency: string
	cardAddress: string
	sun?: { e: string; c: string; m: string }
}): Promise<NfcTopupPrepareResult | null> {
	try {
		const payload: Record<string, string> = {
			amount: body.amount,
			currency: body.currency,
			cardAddress: body.cardAddress,
			workflow: 'adminTopup',
			topupMode: 'admin',
		}
		if (body.uid) payload.uid = body.uid
		if (body.wallet) payload.wallet = body.wallet
		if (body.beamioTag) payload.beamioTag = body.beamioTag
		if (body.sun) {
			payload.e = body.sun.e
			payload.c = body.sun.c
			payload.m = body.sun.m
		}
		const res = await fetch(`${BEAMIO_API}/api/nfcTopupPrepare`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(payload),
		})
		const json = (await res.json()) as Record<string, unknown>
		if (!res.ok) {
			return { error: String(json.error ?? `HTTP ${res.status}`) }
		}
		if (json.error) {
			return { error: String(json.error) }
		}
		const deadlineRaw = json.deadline
		const deadline =
			typeof deadlineRaw === 'number'
				? deadlineRaw
				: Number(String(deadlineRaw ?? '')) || undefined
		return {
			cardAddr: String(json.cardAddr ?? '').trim() || undefined,
			data: String(json.data ?? '').trim() || undefined,
			deadline: deadline && deadline > 0 ? deadline : undefined,
			nonce: String(json.nonce ?? '').trim() || undefined,
			wallet: String(json.wallet ?? '').trim() || undefined,
			factoryGateway: String(json.factoryGateway ?? '').trim() || undefined,
			error: undefined,
		}
	} catch (e) {
		return { error: e instanceof Error ? e.message : 'Network error' }
	}
}

export interface NfcTopupSubmitResult {
	success: boolean
	txHash?: string
	error?: string
}

export async function nfcTopupSubmit(body: {
	uid?: string
	wallet?: string
	cardAddr: string
	data: string
	deadline: number
	nonce: string
	adminSignature: string
	sun?: { e: string; c: string; m: string }
	currencySplit?: {
		currencyAmount: string
		cardCurrencyAmount: string
		cashCurrencyAmount: string
		bonusCurrencyAmount: string
	}
	usdcTopupSessionId?: string
}): Promise<NfcTopupSubmitResult | null> {
	try {
		const payload: Record<string, string | number> = {
			cardAddr: body.cardAddr,
			data: body.data,
			deadline: body.deadline,
			nonce: body.nonce,
			adminSignature: body.adminSignature,
			workflow: 'adminTopup',
			topupMode: 'admin',
		}
		if (body.uid) payload.uid = body.uid
		if (body.wallet) payload.wallet = body.wallet
		if (body.sun) {
			payload.e = body.sun.e
			payload.c = body.sun.c
			payload.m = body.sun.m
		}
		if (body.currencySplit) {
			payload.currencyAmount = body.currencySplit.currencyAmount
			payload.cardCurrencyAmount = body.currencySplit.cardCurrencyAmount
			payload.cashCurrencyAmount = body.currencySplit.cashCurrencyAmount
			payload.bonusCurrencyAmount = body.currencySplit.bonusCurrencyAmount
		}
		if (body.usdcTopupSessionId) {
			payload.usdcTopupSessionId = body.usdcTopupSessionId.toLowerCase()
		}
		const res = await fetch(`${BEAMIO_API}/api/nfcTopup`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(payload),
		})
		const json = (await res.json()) as { success?: boolean; txHash?: string; error?: string }
		const ok = res.ok && (json.success ?? true)
		return {
			success: ok,
			txHash: json.txHash?.trim() || undefined,
			error: json.error?.trim() || (!ok ? `HTTP ${res.status}` : undefined),
		}
	} catch {
		return null
	}
}

export type UsdcChargeSessionState =
	| 'awaiting_payment'
	| 'verifying'
	| 'settling'
	| 'awaiting_topup_auth'
	| 'awaiting_beneficiary'
	| 'topup_pending'
	| 'topup_confirmed'
	| 'charge_pending'
	| 'success'
	| 'error'
	| 'unknown'

export interface UsdcChargeSessionResult {
	ok: boolean
	sid: string
	state: UsdcChargeSessionState
	error?: string
	topupTxHash?: string
	chargeTxHash?: string
	total?: string
	pendingTopupCardAddr?: string
	pendingTopupData?: string
	pendingTopupDeadline?: number
	pendingTopupNonce?: string
	pendingTopupVerifyingContract?: string
}

export interface OracleRatesResponse {
	usdcad: number
	usdeur: number
	usdjpy: number
	usdcny: number
	usdhkd: number
	usdsgd: number
	usdtwd: number
}

export async function fetchOracle(): Promise<OracleRatesResponse | null> {
	try {
		const res = await fetch(`${BEAMIO_API}/api/getOracle`)
		if (!res.ok) return null
		const json = (await res.json()) as Record<string, unknown>
		const rate = (k: string, d: number) => {
			const v = json[k]
			if (typeof v === 'string') return Number(v) || d
			if (typeof v === 'number') return v
			return d
		}
		return {
			usdcad: rate('usdcad', 1.35),
			usdeur: rate('usdeur', 0.92),
			usdjpy: rate('usdjpy', 150),
			usdcny: rate('usdcny', 7.2),
			usdhkd: rate('usdhkd', 7.8),
			usdsgd: rate('usdsgd', 1.35),
			usdtwd: rate('usdtwd', 31),
		}
	} catch {
		return null
	}
}

export interface PayByNfcUidPrepareResult {
	ok: boolean
	account?: string
	nonce?: string
	deadline?: string
	payeeAA?: string
	unitPriceUSDC6?: string
	cardCurrency?: string
	pointsUnitPriceInCurrencyE6?: string
	error?: string
}

export async function payByNfcUidPrepare(body: {
	uid: string
	payee: string
	amountFiat6: string
	currency: string
	merchantInfraCard?: string
	sun?: { e: string; c: string; m: string }
}): Promise<PayByNfcUidPrepareResult | null> {
	try {
		const payload: Record<string, string> = {
			uid: body.uid,
			payee: body.payee,
			amountFiat6: body.amountFiat6,
			currency: body.currency.toUpperCase(),
		}
		if (body.merchantInfraCard?.trim()) {
			payload.merchantInfraCard = body.merchantInfraCard.trim()
		}
		if (body.sun) {
			payload.e = body.sun.e
			payload.c = body.sun.c
			payload.m = body.sun.m
		}
		const res = await fetch(`${BEAMIO_API}/api/payByNfcUidPrepare`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(payload),
		})
		const json = (await res.json()) as Record<string, unknown>
		const ok = Boolean(json.ok ?? res.ok)
		return {
			ok,
			account: json.account ? String(json.account) : undefined,
			nonce: json.nonce ? String(json.nonce) : undefined,
			deadline: json.deadline ? String(json.deadline) : undefined,
			payeeAA: json.payeeAA ? String(json.payeeAA) : undefined,
			unitPriceUSDC6: json.unitPriceUSDC6 ? String(json.unitPriceUSDC6) : undefined,
			cardCurrency: json.cardCurrency ? String(json.cardCurrency) : undefined,
			pointsUnitPriceInCurrencyE6: json.pointsUnitPriceInCurrencyE6
				? String(json.pointsUnitPriceInCurrencyE6)
				: undefined,
			error: json.error ? String(json.error) : undefined,
		}
	} catch {
		return null
	}
}

export interface PayByNfcUidSignResult {
	success: boolean
	txHash?: string
	error?: string
}

export async function payByNfcUidSignContainer(body: {
	uid: string
	containerPayload: Record<string, unknown>
	amountFiat6: string
	currency: string
	merchantInfraCard?: string
	sun?: { e: string; c: string; m: string }
	nfcBill: Record<string, string | number>
}): Promise<PayByNfcUidSignResult | null> {
	try {
		const payload: Record<string, unknown> = {
			uid: body.uid,
			containerPayload: body.containerPayload,
			amountFiat6: body.amountFiat6,
			currency: body.currency.toUpperCase(),
			...body.nfcBill,
		}
		if (body.merchantInfraCard?.trim()) {
			payload.merchantInfraCard = body.merchantInfraCard.trim()
		}
		if (body.sun) {
			payload.e = body.sun.e
			payload.c = body.sun.c
			payload.m = body.sun.m
		}
		const res = await fetch(`${BEAMIO_API}/api/payByNfcUidSignContainer`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(payload),
		})
		const json = (await res.json()) as Record<string, unknown>
		const ok = res.ok && (json.success !== false)
		return {
			success: ok,
			txHash: (json.USDC_tx as string | undefined)?.trim() || undefined,
			error: json.error ? String(json.error) : !ok ? `HTTP ${res.status}` : undefined,
		}
	} catch {
		return null
	}
}

export interface PostAAtoEOAResult {
	success: boolean
	txHash?: string
	error?: string
}

/** iOS `postAAtoEOA` — Scan to Pay dynamic QR charge relay. */
export async function postAAtoEOA(body: {
	openContainerPayload: Record<string, unknown>
	currency: string
	currencyAmount: string
	merchantInfraCard: string
	/** POS terminal EOA → indexer `subordinate` / `accountActionIds(POS)` for `/history`. */
	posOperator: string
	chargeBill: Record<string, string | number>
}): Promise<PostAAtoEOAResult | null> {
	try {
		const posOp = body.posOperator.trim()
		const payload: Record<string, unknown> = {
			openContainerPayload: body.openContainerPayload,
			currency: body.currency.toUpperCase(),
			currencyAmount: body.currencyAmount,
			merchantCardAddress: body.merchantInfraCard.trim(),
			...(posOp.startsWith('0x') && posOp.length === 42 ? { posOperator: posOp } : {}),
			...body.chargeBill,
		}
		const res = await fetch(`${BEAMIO_API}/api/AAtoEOA`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(payload),
		})
		const json = (await res.json()) as Record<string, unknown>
		const ok = res.ok && json.success !== false
		return {
			success: ok,
			txHash: (json.USDC_tx as string | undefined)?.trim() || undefined,
			error: json.error ? String(json.error) : !ok ? `HTTP ${res.status}` : undefined,
		}
	} catch {
		return null
	}
}

export interface UsdcChargePreCheckResult {
	ok: boolean
	error?: string
	cardCurrency?: string
	total?: string
}

export async function fetchUsdcChargePreCheck(params: {
	cardAddress: string
	pos?: string
	subtotal: string
	tipBps: number
	taxBps: number
	discountBps: number
	currency?: string
}): Promise<UsdcChargePreCheckResult | null> {
	const card = params.cardAddress.trim()
	const sub = params.subtotal.trim()
	if (!card.startsWith('0x') || card.length !== 42 || !sub) return null
	try {
		const q = new URLSearchParams({
			card,
			subtotal: sub,
			tipBps: String(Math.max(0, params.tipBps)),
			taxBps: String(Math.max(0, params.taxBps)),
			discountBps: String(Math.max(0, params.discountBps)),
		})
		if (params.pos?.trim()) q.set('pos', params.pos.trim())
		if (params.currency?.trim()) q.set('currency', params.currency.trim().toUpperCase())
		const res = await fetch(`${BEAMIO_API}/api/nfcUsdcChargePreCheck?${q}`)
		const json = (await res.json()) as Record<string, unknown>
		if (!res.ok && json.ok !== true && !json.error) return null
		return {
			ok: Boolean(json.ok),
			error: json.error ? String(json.error) : undefined,
			cardCurrency: json.currency ? String(json.currency) : undefined,
			total: json.total ? String(json.total) : undefined,
		}
	} catch {
		return null
	}
}

export async function fetchUsdcChargeSession(sid: string): Promise<UsdcChargeSessionResult | null> {
	const sidTrim = sid.trim().toLowerCase()
	if (!sidTrim || sidTrim.length !== 36) return null
	try {
		const params = new URLSearchParams({ sid: sidTrim })
		const res = await fetch(`${BEAMIO_API}/api/nfcUsdcChargeSession?${params}`)
		const json = (await res.json()) as Record<string, unknown>
		if (!res.ok) {
			return {
				ok: false,
				sid: sidTrim,
				state: 'unknown',
				error: String(json.error ?? `HTTP ${res.status}`),
			}
		}
		const stateRaw = String(json.state ?? 'unknown')
		return {
			ok: Boolean(json.ok ?? true),
			sid: String(json.sid ?? sidTrim),
			state: stateRaw as UsdcChargeSessionState,
			error: json.error ? String(json.error) : undefined,
			topupTxHash: json.topupTxHash ? String(json.topupTxHash) : undefined,
			chargeTxHash: json.chargeTxHash ? String(json.chargeTxHash) : undefined,
			total: json.total ? String(json.total) : undefined,
			pendingTopupCardAddr: json.pendingTopupCardAddr
				? String(json.pendingTopupCardAddr)
				: undefined,
			pendingTopupData: json.pendingTopupData ? String(json.pendingTopupData) : undefined,
			pendingTopupDeadline:
				typeof json.pendingTopupDeadline === 'number'
					? json.pendingTopupDeadline
					: Number(json.pendingTopupDeadline) || undefined,
			pendingTopupNonce: json.pendingTopupNonce ? String(json.pendingTopupNonce) : undefined,
			pendingTopupVerifyingContract: json.pendingTopupVerifyingContract
				? String(json.pendingTopupVerifyingContract)
				: undefined,
		}
	} catch {
		return null
	}
}

export async function submitUsdcChargeTopupAuth(
	sid: string,
	signature: string,
): Promise<{ ok: boolean; errorMessage?: string } | null> {
	const sidTrim = sid.trim().toLowerCase()
	const sigTrim = signature.trim()
	if (!sidTrim || sigTrim.length < 130) return null
	try {
		const res = await fetch(`${BEAMIO_API}/api/nfcUsdcChargeTopupAuth`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ sid: sidTrim, signature: sigTrim }),
		})
		const json = (await res.json()) as { success?: boolean; error?: string }
		if (res.ok && json.success) {
			return { ok: true }
		}
		return { ok: false, errorMessage: json.error ?? `HTTP ${res.status}` }
	} catch {
		return null
	}
}

export function numFromLedger(v: unknown): number | null {
	if (v == null || v === '') return null
	const n = Number(v)
	return Number.isFinite(n) ? n : null
}

export async function fetchUIDAssets(params: {
	uid: string
	merchantInfraCard: string
	sun?: { e: string; c: string; m: string }
}): Promise<UIDAssetsResult | null> {
	const uid = params.uid.trim()
	const merchantInfraCard = params.merchantInfraCard.trim()
	if (!uid || !merchantInfraCard) return null
	try {
		const body: Record<string, string> = { uid, merchantInfraCard }
		if (params.sun) {
			body.e = params.sun.e
			body.c = params.sun.c
			body.m = params.sun.m
		}
		const res = await fetch(`${BEAMIO_API}/api/getUIDAssets`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
		})
		if (!res.ok) return null
		const json = await res.json()
		return parseUIDAssetsResponse(json)
	} catch {
		return null
	}
}

export async function fetchWalletAssetsForRead(params: {
	wallet: string
	merchantInfraCard: string
	/** iOS `getWalletAssets(..., forPostPayment: true)` after QR charge. */
	forPostPayment?: boolean
}): Promise<UIDAssetsResult | null> {
	const wallet = params.wallet.trim()
	const merchantInfraCard = params.merchantInfraCard.trim()
	if (!wallet || !merchantInfraCard) return null
	try {
		const body: Record<string, string> = { wallet, merchantInfraCard }
		if (params.forPostPayment) body.for = 'postPaymentBalance'
		const res = await fetch(`${BEAMIO_API}/api/getWalletAssets`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
		})
		if (!res.ok) return null
		const json = await res.json()
		return parseUIDAssetsResponse(json)
	} catch {
		return null
	}
}

export interface CardCouponPosClaimResult {
	success: boolean
	txHash?: string
	error?: string
}

export interface CardCouponPosClaimPrepareResult {
	success: boolean
	cardAddress?: string
	couponId?: string
	userEOA?: string
	tokenId?: string
	data?: string
	deadline?: number
	nonce?: string
	factoryGateway?: string
	error?: string
}

export interface CardCouponPosClaimSubmitResult {
	success: boolean
	txHash?: string
	error?: string
}

export interface CardCouponPosConsumePrepareResult {
	success: boolean
	cardAddress?: string
	data?: string
	deadline?: number
	nonce?: string
	factoryGateway?: string
	tokenId?: string
	amount?: string
	targetAddress?: string
	error?: string
}

export interface CardCouponPosConsumeSubmitResult {
	success: boolean
	txHash?: string
	error?: string
}

export interface BurnChargeRewardPrepareResult {
	success: boolean
	cardAddr?: string
	data?: string
	deadline?: number
	nonce?: string
	factoryGateway?: string
	error?: string
}

/** Burn charge-reward points (token #2) — iOS `burnChargeRewardByAdminPrepare`. */
export async function burnChargeRewardByAdminPrepare(params: {
	cardAddress: string
	target: string
	amount: string
}): Promise<BurnChargeRewardPrepareResult | null> {
	const card = params.cardAddress.trim()
	const target = params.target.trim()
	const amount = params.amount.trim()
	if (!card.startsWith('0x') || !target.startsWith('0x') || !amount) {
		return { success: false, error: 'Invalid burn payload.' }
	}
	try {
		const res = await fetch(`${BEAMIO_API}/api/burnChargeRewardByAdminPrepare`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ cardAddress: card, target, amount }),
		})
		const json = (await res.json()) as Record<string, unknown>
		if (!res.ok) {
			return { success: false, error: String(json.error ?? `HTTP ${res.status}`) }
		}
		const data = String(json.data ?? '').trim() || undefined
		const nonce = String(json.nonce ?? '').trim() || undefined
		const deadlineRaw = json.deadline
		const deadline =
			typeof deadlineRaw === 'number'
				? deadlineRaw
				: Number(String(deadlineRaw ?? '')) || undefined
		const cardAddr = String(json.cardAddr ?? card).trim() || card
		const factoryGateway = String(json.factoryGateway ?? '').trim() || undefined
		if (!data || !nonce || !deadline || deadline <= 0) {
			return {
				success: false,
				cardAddr,
				data,
				deadline,
				nonce,
				factoryGateway,
				error: String(json.error ?? 'Prepare failed.'),
			}
		}
		return {
			success: true,
			cardAddr,
			data,
			deadline,
			nonce,
			factoryGateway,
		}
	} catch {
		return null
	}
}

/** POS one-tap open-coupon claim — NFC path only (uid/tagId present). QR/wallet uses prepare+submit. */
export async function cardCouponPosClaim(params: {
	cardAddress: string
	couponId: string
	userEOA: string
	uid?: string
	tagIdHex?: string
	tokenId?: string
	signerEOA?: string
}): Promise<CardCouponPosClaimResult | null> {
	const card = params.cardAddress.trim()
	const couponId = params.couponId.trim()
	const userEOA = params.userEOA.trim()
	if (!isPlausibleEvmAddress(card) || !isPlausibleEvmAddress(userEOA) || !couponId) {
		return { success: false, error: 'Invalid claim payload.' }
	}
	const body: Record<string, string> = {
		cardAddress: card,
		couponId,
		userEOA,
	}
	const uid = params.uid?.trim()
	const tagIdHex = params.tagIdHex?.trim()
	const tokenId = params.tokenId?.trim()
	const signerEOA = params.signerEOA?.trim()
	if (uid) body.uid = uid
	if (tagIdHex) body.tagIdHex = tagIdHex
	if (tokenId) body.tokenId = tokenId
	if (isPlausibleEvmAddress(signerEOA)) body.signerEOA = signerEOA!
	try {
		const res = await fetch(`${BEAMIO_API}/api/cardCouponPosClaim`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
		})
		const json = (await res.json()) as { success?: boolean; tx?: string; error?: string }
		const ok = res.ok && (json.success ?? true)
		return {
			success: ok,
			txHash: json.tx?.trim() || undefined,
			error: json.error?.trim() || (!ok ? `HTTP ${res.status}` : undefined),
		}
	} catch {
		return null
	}
}

/** POS balance open-coupon claim prepare — aligns consume prepare pattern. */
export async function cardCouponPosClaimPrepare(params: {
	cardAddress: string
	couponId: string
	userEOA: string
	signerEOA?: string
	tokenId?: string
}): Promise<CardCouponPosClaimPrepareResult | null> {
	const card = params.cardAddress.trim()
	const couponId = params.couponId.trim()
	const userEOA = params.userEOA.trim()
	if (!isPlausibleEvmAddress(card) || !isPlausibleEvmAddress(userEOA) || !couponId) {
		return { success: false, error: 'Invalid claim payload.' }
	}
	const body: Record<string, string> = {
		cardAddress: card,
		couponId,
		userEOA,
	}
	const tokenId = params.tokenId?.trim()
	const signerEOA = params.signerEOA?.trim()
	if (tokenId) body.tokenId = tokenId
	if (isPlausibleEvmAddress(signerEOA)) body.signerEOA = signerEOA!
	try {
		const res = await fetch(`${BEAMIO_API}/api/cardCouponPosClaimPrepare`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
		})
		const json = (await res.json()) as CardCouponPosClaimPrepareResult
		if (!res.ok) {
			return { success: false, error: json.error?.trim() || `HTTP ${res.status}` }
		}
		return json
	} catch {
		return null
	}
}

/** Submit admin-signed ExecuteForAdmin for open-coupon claim. */
export async function cardCouponPosClaimSubmit(params: {
	cardAddress: string
	data: string
	deadline: number
	nonce: string
	adminSignature: string
	signerEOA?: string
}): Promise<CardCouponPosClaimSubmitResult | null> {
	const cardAddress = params.cardAddress.trim()
	const data = params.data.trim()
	const nonce = params.nonce.trim()
	const adminSignature = params.adminSignature.trim()
	if (!isPlausibleEvmAddress(cardAddress) || !data || !nonce || !adminSignature) {
		return { success: false, error: 'Invalid claim submit payload.' }
	}
	const body: Record<string, string | number> = {
		cardAddress,
		data,
		deadline: params.deadline,
		nonce,
		adminSignature,
	}
	const signerEOA = params.signerEOA?.trim()
	if (isPlausibleEvmAddress(signerEOA)) body.signerEOA = signerEOA!
	try {
		const res = await fetch(`${BEAMIO_API}/api/cardCouponPosClaimSubmit`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
		})
		const json = (await res.json()) as CardCouponPosClaimSubmitResult & { tx?: string }
		const ok = res.ok && (json.success ?? true)
		return {
			success: ok,
			txHash: json.txHash?.trim() || json.tx?.trim() || undefined,
			error: json.error?.trim() || (!ok ? `HTTP ${res.status}` : undefined),
		}
	} catch {
		return null
	}
}

/** POS balance coupon consume prepare — aligns iOS `BeamioAPIClient.cardCouponPosConsumePrepare`. */
export async function cardCouponPosConsumePrepare(params: {
	cardAddress: string
	couponId: string
	userEOA: string
	signerEOA?: string
	tokenId?: string
	amount?: string
}): Promise<CardCouponPosConsumePrepareResult | null> {
	const card = params.cardAddress.trim()
	const couponId = params.couponId.trim()
	const userEOA = params.userEOA.trim()
	const amount = (params.amount ?? '1').trim()
	if (!isPlausibleEvmAddress(card) || !isPlausibleEvmAddress(userEOA) || !couponId || !amount) {
		return { success: false, error: 'Invalid consume payload.' }
	}
	const body: Record<string, string> = {
		cardAddress: card,
		couponId,
		userEOA,
		amount,
	}
	const signerEOA = params.signerEOA?.trim()
	const tokenId = params.tokenId?.trim()
	if (isPlausibleEvmAddress(signerEOA)) body.signerEOA = signerEOA!
	if (tokenId) body.tokenId = tokenId
	try {
		const res = await fetch(`${BEAMIO_API}/api/cardCouponPosConsumePrepare`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
		})
		const json = (await res.json()) as Record<string, unknown>
		const ok = res.ok && json.success !== false
		const deadlineRaw = json.deadline
		const deadline =
			typeof deadlineRaw === 'number'
				? deadlineRaw
				: Number(String(deadlineRaw ?? '')) || undefined
		return {
			success: ok,
			cardAddress: String(json.cardAddress ?? '').trim() || undefined,
			data: String(json.data ?? '').trim() || undefined,
			deadline: deadline && deadline > 0 ? deadline : undefined,
			nonce: String(json.nonce ?? '').trim() || undefined,
			factoryGateway: String(json.factoryGateway ?? '').trim() || undefined,
			tokenId: String(json.tokenId ?? '').trim() || undefined,
			amount: String(json.amount ?? '').trim() || undefined,
			targetAddress: String(json.targetAddress ?? '').trim() || undefined,
			error: String(json.error ?? '').trim() || (!ok ? `HTTP ${res.status}` : undefined),
		}
	} catch {
		return null
	}
}

/** Submit admin-signed ExecuteForAdmin for coupon consume — aligns iOS `cardCouponPosConsumeSubmit`. */
export async function cardCouponPosConsumeSubmit(params: {
	cardAddress: string
	data: string
	deadline: number
	nonce: string
	adminSignature: string
	signerEOA?: string
}): Promise<CardCouponPosConsumeSubmitResult | null> {
	const card = params.cardAddress.trim()
	const data = params.data.trim()
	const nonce = params.nonce.trim()
	const adminSignature = params.adminSignature.trim()
	if (!isPlausibleEvmAddress(card) || !data || !nonce || !adminSignature) {
		return { success: false, error: 'Invalid consume submit payload.' }
	}
	const body: Record<string, string | number> = {
		cardAddress: card,
		data,
		deadline: params.deadline,
		nonce,
		adminSignature,
	}
	const signerEOA = params.signerEOA?.trim()
	if (isPlausibleEvmAddress(signerEOA)) body.signerEOA = signerEOA!
	try {
		const res = await fetch(`${BEAMIO_API}/api/cardCouponPosConsumeSubmit`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
		})
		const json = (await res.json()) as Record<string, unknown>
		const ok = res.ok && json.success !== false
		const txHash = String(json.txHash ?? json.tx ?? '').trim() || undefined
		return {
			success: ok,
			txHash,
			error: String(json.error ?? '').trim() || (!ok ? `HTTP ${res.status}` : undefined),
		}
	} catch {
		return null
	}
}
