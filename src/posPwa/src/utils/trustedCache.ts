import type { PosHomeStats, TerminalProfile } from '@/types/pos'
import type { MerchantActiveIssuedCoupon } from '@/utils/couponMetadata'
import type { PosLedgerSnapshot } from '@/utils/posLedgerMetrics'

const PREFIX = 'beamio:pos-pwa:v1'

function normWallet(wallet: string): string {
	return wallet.trim().toLowerCase()
}

function normInfra(infra: string): string {
	return infra.trim().toLowerCase()
}

function key(...parts: string[]): string {
	return `${PREFIX}:${parts.join(':')}`
}

/** Local-first home cache — only write on trusted success. */
export const posHomeTrustedCache = {
	loadProfiles(wallet: string): { terminal: TerminalProfile | null; admin: TerminalProfile | null } {
		try {
			const t = localStorage.getItem(key('term', normWallet(wallet)))
			const a = localStorage.getItem(key('admin', normWallet(wallet)))
			return {
				terminal: t ? (JSON.parse(t) as TerminalProfile) : null,
				admin: a ? (JSON.parse(a) as TerminalProfile) : null,
			}
		} catch {
			return { terminal: null, admin: null }
		}
	},

	saveTerminal(profile: TerminalProfile, wallet: string): void {
		try {
			localStorage.setItem(key('term', normWallet(wallet)), JSON.stringify(profile))
		} catch {
			/* ignore quota */
		}
	},

	saveAdmin(profile: TerminalProfile, wallet: string): void {
		try {
			localStorage.setItem(key('admin', normWallet(wallet)), JSON.stringify(profile))
		} catch {
			/* ignore quota */
		}
	},

	removeAdmin(wallet: string): void {
		try {
			localStorage.removeItem(key('admin', normWallet(wallet)))
		} catch {
			/* ignore */
		}
	},

	loadStats(wallet: string, infraCard: string): PosHomeStats {
		try {
			const raw = localStorage.getItem(key('stats', normWallet(wallet), normInfra(infraCard)))
			if (!raw) return { charge: null, topUp: null, tips: null, chargeUsdc: null, tipsUsdc: null }
			return JSON.parse(raw) as PosHomeStats
		} catch {
			return { charge: null, topUp: null, tips: null, chargeUsdc: null, tipsUsdc: null }
		}
	},

	mergeAndSaveStats(
		wallet: string,
		infraCard: string,
		patch: Partial<PosHomeStats>,
	): void {
		const prev = posHomeTrustedCache.loadStats(wallet, infraCard)
		const next: PosHomeStats = { ...prev, ...pickDefined(patch) }
		try {
			localStorage.setItem(
				key('stats', normWallet(wallet), normInfra(infraCard)),
				JSON.stringify(next),
			)
		} catch {
			/* ignore */
		}
	},

	loadParentTag(wallet: string): string | null {
		try {
			return localStorage.getItem(key('parentTag', normWallet(wallet)))
		} catch {
			return null
		}
	},

	saveParentTag(wallet: string, tag: string): void {
		try {
			localStorage.setItem(key('parentTag', normWallet(wallet)), tag)
		} catch {
			/* ignore */
		}
	},

	loadRegisteredTag(wallet: string): string | null {
		try {
			return localStorage.getItem(key('registeredTag', normWallet(wallet)))
		} catch {
			return null
		}
	},

	saveRegisteredTag(wallet: string, tag: string): void {
		try {
			localStorage.setItem(key('registeredTag', normWallet(wallet)), tag)
		} catch {
			/* ignore */
		}
	},

	loadParentProfile(wallet: string): TerminalProfile | null {
		try {
			const raw = localStorage.getItem(key('parentProfile', normWallet(wallet)))
			if (!raw) return null
			return JSON.parse(raw) as TerminalProfile
		} catch {
			return null
		}
	},

	saveParentProfile(profile: TerminalProfile, wallet: string): void {
		try {
			localStorage.setItem(key('parentProfile', normWallet(wallet)), JSON.stringify(profile))
		} catch {
			/* ignore quota */
		}
	},

	loadInfraCard(wallet: string): string | null {
		try {
			return localStorage.getItem(key('infra', normWallet(wallet)))
		} catch {
			return null
		}
	},

	saveInfraCard(wallet: string, card: string): void {
		try {
			localStorage.setItem(key('infra', normWallet(wallet)), card)
		} catch {
			/* ignore */
		}
	},

	loadPosLedger(wallet: string, infraCard: string): PosLedgerSnapshot | null {
		try {
			const raw = localStorage.getItem(key('ledger', normWallet(wallet), normInfra(infraCard)))
			if (!raw) return null
			return JSON.parse(raw) as PosLedgerSnapshot
		} catch {
			return null
		}
	},

	savePosLedger(snapshot: PosLedgerSnapshot, wallet: string, infraCard: string): void {
		try {
			localStorage.setItem(
				key('ledger', normWallet(wallet), normInfra(infraCard)),
				JSON.stringify(snapshot),
			)
		} catch {
			/* ignore quota */
		}
	},

	loadPermissionGranted(wallet: string): boolean | null {
		try {
			const v = localStorage.getItem(key('perm', normWallet(wallet)))
			if (v === '1') return true
			if (v === '0') return false
			return null
		} catch {
			return null
		}
	},

	savePermissionGranted(wallet: string, granted: boolean): void {
		try {
			localStorage.setItem(key('perm', normWallet(wallet)), granted ? '1' : '0')
		} catch {
			/* ignore */
		}
	},

	/** True when terminal was previously approved then removed from merchant card admin list. */
	loadAdminAccessRevoked(wallet: string): boolean {
		try {
			return localStorage.getItem(key('adminRevoked', normWallet(wallet))) === '1'
		} catch {
			return false
		}
	},

	saveAdminAccessRevoked(wallet: string, revoked: boolean): void {
		try {
			if (revoked) {
				localStorage.setItem(key('adminRevoked', normWallet(wallet)), '1')
			} else {
				localStorage.removeItem(key('adminRevoked', normWallet(wallet)))
			}
		} catch {
			/* ignore */
		}
	},

	loadPointSystemEnabled(wallet: string, infraCard: string): boolean | null {
		try {
			const v = localStorage.getItem(
				key('pointSystem', normWallet(wallet), normInfra(infraCard)),
			)
			if (v === '1') return true
			if (v === '0') return false
			return null
		} catch {
			return null
		}
	},

	savePointSystemEnabled(wallet: string, infraCard: string, enabled: boolean): void {
		try {
			localStorage.setItem(
				key('pointSystem', normWallet(wallet), normInfra(infraCard)),
				enabled ? '1' : '0',
			)
		} catch {
			/* ignore */
		}
	},

	/** Last trusted `/api/cardActiveIssuedCouponSeries` list — `null` = never cached. */
	loadActiveCoupons(wallet: string, infraCard: string): MerchantActiveIssuedCoupon[] | null {
		try {
			const raw = localStorage.getItem(
				key('activeCoupons', normWallet(wallet), normInfra(infraCard)),
			)
			if (!raw) return null
			const parsed = JSON.parse(raw) as unknown
			if (!Array.isArray(parsed)) return null
			return parsed as MerchantActiveIssuedCoupon[]
		} catch {
			return null
		}
	},

	/** Only call after a trusted API success (including trusted-empty `[]`). */
	saveActiveCoupons(
		wallet: string,
		infraCard: string,
		coupons: MerchantActiveIssuedCoupon[],
	): void {
		try {
			localStorage.setItem(
				key('activeCoupons', normWallet(wallet), normInfra(infraCard)),
				JSON.stringify(coupons),
			)
		} catch {
			/* ignore quota */
		}
	},

	loadProgramCardBusinessName(wallet: string, infraCard: string): string | null {
		try {
			return localStorage.getItem(
				key('programBizName', normWallet(wallet), normInfra(infraCard)),
			)
		} catch {
			return null
		}
	},

	saveProgramCardBusinessName(
		wallet: string,
		infraCard: string,
		name: string | null,
	): void {
		try {
			const k = key('programBizName', normWallet(wallet), normInfra(infraCard))
			if (name?.trim()) localStorage.setItem(k, name.trim())
			else localStorage.removeItem(k)
		} catch {
			/* ignore quota */
		}
	},
}

function pickDefined<T extends Record<string, unknown>>(obj: T): Partial<T> {
	const out: Partial<T> = {}
	for (const [k, v] of Object.entries(obj)) {
		if (v !== undefined) (out as Record<string, unknown>)[k] = v
	}
	return out
}
