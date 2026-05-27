import { fetchCardAdminInfo } from '@/api/beamioApi'
import { BASE_RPC } from '@/constants'
import type { CardAdminInfoResponse, MyPosAddressResponse } from '@/types/pos'

const OWNER_SELECTOR = '0x8da5cb5b'
const IS_ADMIN_SELECTOR = '0x24d7806c'

/** API returns `cardAddress`; legacy clients used `merchantInfraCard`. */
export function parseMerchantInfraCardFromMyPos(
	res: MyPosAddressResponse | null | undefined,
): string | null {
	if (!res) return null
	const raw =
		res.merchantInfraCard?.trim() ||
		res.cardAddress?.trim() ||
		res.myPosAddress?.trim()
	return raw && raw.startsWith('0x') && raw.length >= 42 ? raw : null
}

/**
 * Align iOS `walletHasTrustedInfraPosHomeAccess` / Android equivalent:
 * owner, upperAdmin, or wallet listed in `admins`.
 */
export function walletHasTrustedInfraPosHomeAccess(
	info: CardAdminInfoResponse | null | undefined,
	walletLower: string,
): boolean {
	if (!info?.ok) return false
	const wl = walletLower.trim().toLowerCase()
	if (!wl.startsWith('0x')) return false
	const ow = info.owner?.trim().toLowerCase() ?? ''
	if (ow && wl === ow) return true
	const ua = info.upperAdmin?.trim().toLowerCase() ?? ''
	if (ua && wl === ua) return true
	return (info.admins ?? []).some((a) => a.trim().toLowerCase() === wl)
}

function decodeAbiAddressWord(hex: string): string | null {
	const h = hex.startsWith('0x') ? hex.slice(2) : hex
	if (h.length < 64) return null
	const body = h.slice(-40)
	if (!/^[0-9a-fA-F]{40}$/.test(body)) return null
	return `0x${body}`.toLowerCase()
}

function decodeAbiBoolWord(hex: string): boolean | null {
	const h = hex.startsWith('0x') ? hex.slice(2) : hex
	if (h.length < 64) return null
	return h.endsWith('1')
}

/** Base chain: `owner()==wallet` or `isAdmin(wallet)`. `null` = RPC untrusted. */
export async function fetchPosProgramCardHomeAccessAllowed(
	cardAddress: string,
	wallet: string,
): Promise<boolean | null> {
	const card = cardAddress.trim()
	const wal = wallet.trim()
	if (!card.startsWith('0x') || card.length !== 42) return null
	if (!wal.startsWith('0x') || wal.length !== 42) return null
	const cardHex = card.toLowerCase()
	const walBody = wal.slice(2).toLowerCase()
	if (walBody.length !== 40 || !/^[0-9a-f0-9]+$/.test(walBody)) return null

	try {
		const ownerRes = await ethCallBase(cardHex, OWNER_SELECTOR)
		if (!ownerRes) return null
		const owner40 = decodeAbiAddressWord(ownerRes)?.slice(2)
		if (owner40 && owner40 === walBody) return true

		const isAdminData = IS_ADMIN_SELECTOR + walBody.padStart(64, '0')
		const isAdminRes = await ethCallBase(cardHex, isAdminData)
		if (!isAdminRes) return null
		const isAdm = decodeAbiBoolWord(isAdminRes)
		return isAdm ?? null
	} catch {
		return null
	}
}

async function ethCallBase(to: string, data: string): Promise<string | null> {
	try {
		const res = await fetch(BASE_RPC, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				jsonrpc: '2.0',
				method: 'eth_call',
				params: [{ to, data }, 'latest'],
				id: 1,
			}),
		})
		if (!res.ok) return null
		const json = (await res.json()) as { error?: unknown; result?: string }
		if (json.error || !json.result || json.result === '0x') return null
		return json.result
	} catch {
		return null
	}
}

/**
 * Prefer on-chain owner/isAdmin; fall back to HTTP getCardAdminInfo (admins / upperAdmin).
 * `null` = both paths untrusted — caller must not treat as denied.
 */
export async function resolvePosTerminalAccessAllowed(
	cardAddress: string,
	wallet: string,
	adminInfo?: CardAdminInfoResponse | null,
): Promise<boolean | null> {
	const chain = await fetchPosProgramCardHomeAccessAllowed(cardAddress, wallet)
	if (chain !== null) return chain

	let info = adminInfo
	if (info === undefined) {
		info = await fetchCardAdminInfo(cardAddress, wallet)
	}
	if (!info?.ok) return null
	return walletHasTrustedInfraPosHomeAccess(info, wallet)
}
