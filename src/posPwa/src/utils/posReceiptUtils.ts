import { shortAddress } from '@/utils/display'
import { normalizeTierDiscountPercent } from '@/utils/beamioPaymentRouting'

export function formatPosReceiptDate(date: Date = new Date()): string {
	const d = date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
	const t = date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })
	return `${d}, ${t}`
}

export function shortTxHash(hash: string): string {
	const h = hash.trim()
	if (h.length > 12) return `${h.slice(0, 7)}…${h.slice(-5)}`
	return h
}

export function shortWalletAddr(address: string | undefined | null): string | null {
	const a = address?.trim()
	if (!a) return null
	if (a.length > 10) return shortAddress(a)
	return a
}

function normalizeTxHashPath(txHash: string): string | null {
	const t = txHash.trim()
	if (!t) return null
	let path = t
	if (!path.startsWith('0x') && !path.startsWith('0X') && path.length === 64 && /^[0-9a-fA-F]+$/.test(path)) {
		path = `0x${path.toLowerCase()}`
	}
	return path
}

export function baseScanTxUrl(txHash: string): string | null {
	const path = normalizeTxHashPath(txHash)
	if (!path) return null
	return `https://basescan.org/tx/${path}`
}

/** Coupon / merchant-card ledger txs settle on CoNET, not Base. */
export function conetMainnetTxUrl(txHash: string): string | null {
	const path = normalizeTxHashPath(txHash)
	if (!path) return null
	return `https://mainnet.conet.network/tx/${path}`
}

export function beamioTierDiscountFiatAmount(subtotal: number, tierDiscountPercent: number): number {
	const p = normalizeTierDiscountPercent(tierDiscountPercent)
	return Math.max(0, subtotal * (p / 100))
}

export function programCardDisplayLine(cardName: string | undefined | null): string {
	const raw = cardName?.trim() ?? ''
	if (!raw) return '—'
	const n = raw.replace(/\s+CARD$/i, '').replace(/\s+Card$/i, '').trim()
	return n || '—'
}

export function paymentSuccessMemberTitle(params: {
	customerBeamioTag?: string
	customerWalletAddress?: string
	cardName?: string
}): string {
	let tag = params.customerBeamioTag?.trim() ?? ''
	if (tag.startsWith('@')) tag = tag.slice(1)
	if (tag) return tag
	const addr = params.customerWalletAddress?.trim()
	if (addr?.startsWith('0x') && addr.length >= 10) return shortAddress(addr)
	const name = programCardDisplayLine(params.cardName)
	if (name !== '—') return name
	return 'Member'
}
