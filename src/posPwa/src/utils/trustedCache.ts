import type { PosHomeStats, TerminalProfile } from '@/types/pos'
import type { MerchantActiveIssuedCoupon } from '@/utils/couponMetadata'
import type { PosLedgerSnapshot } from '@/utils/posLedgerMetrics'

/** Legacy single-slot keys (pre multi-merchant). */
const PREFIX_V1 = 'beamio:pos-pwa:v1'
/** Workspace-partitioned keys: wallet + upperAdminEoa. */
const PREFIX_V2 = 'beamio:pos-pwa:v2'

function normAddr(addr: string): string {
	return addr.trim().toLowerCase()
}

function v1Key(...parts: string[]): string {
	return `${PREFIX_V1}:${parts.join(':')}`
}

function globalKey(...parts: string[]): string {
	return `${PREFIX_V2}:${parts.join(':')}`
}

function wsKey(wallet: string, upperEoa: string, ...parts: string[]): string {
	return `${PREFIX_V2}:ws:${normAddr(wallet)}:${normAddr(upperEoa)}:${parts.join(':')}`
}

function pickDefined<T extends Record<string, unknown>>(obj: T): Partial<T> {
	const out: Partial<T> = {}
	for (const [k, v] of Object.entries(obj)) {
		if (v !== undefined) (out as Record<string, unknown>)[k] = v
	}
	return out
}

function readJson<T>(raw: string | null): T | null {
	if (!raw) return null
	try {
		return JSON.parse(raw) as T
	} catch {
		return null
	}
}

/**
 * One-time: copy v1 wallet-only / wallet+infra slots into this upper workspace
 * so switching merchants does not lose prior KPI / capsule data.
 */
function migrateV1IntoWorkspace(wallet: string, upperEoa: string): void {
	const w = normAddr(wallet)
	const u = normAddr(upperEoa)
	if (!w || !u) return
	const flag = globalKey('migratedV1', w, u)
	try {
		if (localStorage.getItem(flag) === '1') return

		const copyIfMissing = (from: string, to: string) => {
			if (localStorage.getItem(to) != null) return
			const v = localStorage.getItem(from)
			if (v != null) localStorage.setItem(to, v)
		}

		copyIfMissing(v1Key('admin', w), wsKey(w, u, 'admin'))
		copyIfMissing(v1Key('parentTag', w), wsKey(w, u, 'parentTag'))
		copyIfMissing(v1Key('parentProfile', w), wsKey(w, u, 'parentProfile'))
		copyIfMissing(v1Key('perm', w), wsKey(w, u, 'perm'))
		copyIfMissing(v1Key('infra', w), wsKey(w, u, 'infra'))

		const infra = localStorage.getItem(wsKey(w, u, 'infra')) ?? localStorage.getItem(v1Key('infra', w))
		if (infra) {
			const i = normAddr(infra)
			copyIfMissing(v1Key('stats', w, i), wsKey(w, u, 'stats', i))
			copyIfMissing(v1Key('ledger', w, i), wsKey(w, u, 'ledger', i))
			copyIfMissing(v1Key('pointSystem', w, i), wsKey(w, u, 'pointSystem', i))
			copyIfMissing(v1Key('activeCoupons', w, i), wsKey(w, u, 'activeCoupons', i))
		}

		localStorage.setItem(flag, '1')
	} catch {
		/* ignore quota / private mode */
	}
}

export type PosOutboundJoinPending = {
	parentTag: string
	parentEoa: string
	requestedAt: number
}

/** Local-first home cache — workspace-partitioned; only write on trusted success. */
export const posHomeTrustedCache = {
	loadActiveUpper(wallet: string): string | null {
		try {
			const v = localStorage.getItem(globalKey('activeUpper', normAddr(wallet)))
			return v?.trim() || null
		} catch {
			return null
		}
	},

	saveActiveUpper(wallet: string, upperEoa: string): void {
		try {
			const u = normAddr(upperEoa)
			if (!u) return
			localStorage.setItem(globalKey('activeUpper', normAddr(wallet)), u)
			migrateV1IntoWorkspace(wallet, u)
		} catch {
			/* ignore */
		}
	},

	/** Ensure v1→v2 migrate for this workspace (idempotent). */
	ensureWorkspace(wallet: string, upperEoa: string): void {
		migrateV1IntoWorkspace(wallet, upperEoa)
	},

	loadProfiles(
		wallet: string,
		upperEoa: string | null | undefined,
	): { terminal: TerminalProfile | null; admin: TerminalProfile | null } {
		try {
			const t =
				localStorage.getItem(globalKey('term', normAddr(wallet))) ??
				localStorage.getItem(v1Key('term', normAddr(wallet)))
			let admin: TerminalProfile | null = null
			if (upperEoa) {
				migrateV1IntoWorkspace(wallet, upperEoa)
				const a = localStorage.getItem(wsKey(wallet, upperEoa, 'admin'))
				admin = readJson<TerminalProfile>(a)
			}
			return {
				terminal: readJson<TerminalProfile>(t),
				admin,
			}
		} catch {
			return { terminal: null, admin: null }
		}
	},

	saveTerminal(profile: TerminalProfile, wallet: string): void {
		try {
			localStorage.setItem(globalKey('term', normAddr(wallet)), JSON.stringify(profile))
			// Keep v1 mirror for older recover scanners
			localStorage.setItem(v1Key('term', normAddr(wallet)), JSON.stringify(profile))
		} catch {
			/* ignore quota */
		}
	},

	saveAdmin(profile: TerminalProfile, wallet: string, upperEoa: string): void {
		try {
			migrateV1IntoWorkspace(wallet, upperEoa)
			localStorage.setItem(wsKey(wallet, upperEoa, 'admin'), JSON.stringify(profile))
		} catch {
			/* ignore quota */
		}
	},

	removeAdmin(wallet: string, upperEoa: string): void {
		try {
			localStorage.removeItem(wsKey(wallet, upperEoa, 'admin'))
		} catch {
			/* ignore */
		}
	},

	loadStats(wallet: string, upperEoa: string, infraCard: string): PosHomeStats {
		try {
			migrateV1IntoWorkspace(wallet, upperEoa)
			const raw = localStorage.getItem(
				wsKey(wallet, upperEoa, 'stats', normAddr(infraCard)),
			)
			if (!raw) return { charge: null, topUp: null, tips: null, chargeUsdc: null, tipsUsdc: null }
			return JSON.parse(raw) as PosHomeStats
		} catch {
			return { charge: null, topUp: null, tips: null, chargeUsdc: null, tipsUsdc: null }
		}
	},

	mergeAndSaveStats(
		wallet: string,
		upperEoa: string,
		infraCard: string,
		patch: Partial<PosHomeStats>,
	): void {
		const prev = posHomeTrustedCache.loadStats(wallet, upperEoa, infraCard)
		const next: PosHomeStats = { ...prev, ...pickDefined(patch) }
		try {
			localStorage.setItem(
				wsKey(wallet, upperEoa, 'stats', normAddr(infraCard)),
				JSON.stringify(next),
			)
		} catch {
			/* ignore */
		}
	},

	/**
	 * Parent tag for a workspace. Without upperEoa, reads staging / v1 (onboarding / recover).
	 */
	loadParentTag(wallet: string, upperEoa?: string | null): string | null {
		try {
			if (upperEoa) {
				migrateV1IntoWorkspace(wallet, upperEoa)
				const ws = localStorage.getItem(wsKey(wallet, upperEoa, 'parentTag'))
				if (ws) return ws
			}
			return (
				localStorage.getItem(globalKey('pendingParentTag', normAddr(wallet))) ??
				localStorage.getItem(v1Key('parentTag', normAddr(wallet)))
			)
		} catch {
			return null
		}
	},

	saveParentTag(wallet: string, tag: string, upperEoa?: string | null): void {
		try {
			if (upperEoa) {
				migrateV1IntoWorkspace(wallet, upperEoa)
				localStorage.setItem(wsKey(wallet, upperEoa, 'parentTag'), tag)
			} else {
				localStorage.setItem(globalKey('pendingParentTag', normAddr(wallet)), tag)
				localStorage.setItem(v1Key('parentTag', normAddr(wallet)), tag)
			}
		} catch {
			/* ignore */
		}
	},

	loadRegisteredTag(wallet: string): string | null {
		try {
			return (
				localStorage.getItem(globalKey('registeredTag', normAddr(wallet))) ??
				localStorage.getItem(v1Key('registeredTag', normAddr(wallet)))
			)
		} catch {
			return null
		}
	},

	saveRegisteredTag(wallet: string, tag: string): void {
		try {
			localStorage.setItem(globalKey('registeredTag', normAddr(wallet)), tag)
			localStorage.setItem(v1Key('registeredTag', normAddr(wallet)), tag)
		} catch {
			/* ignore */
		}
	},

	loadParentProfile(wallet: string, upperEoa: string | null | undefined): TerminalProfile | null {
		try {
			if (!upperEoa) {
				const staging =
					localStorage.getItem(globalKey('pendingParentProfile', normAddr(wallet))) ??
					localStorage.getItem(v1Key('parentProfile', normAddr(wallet)))
				return readJson<TerminalProfile>(staging)
			}
			migrateV1IntoWorkspace(wallet, upperEoa)
			return readJson<TerminalProfile>(localStorage.getItem(wsKey(wallet, upperEoa, 'parentProfile')))
		} catch {
			return null
		}
	},

	saveParentProfile(profile: TerminalProfile, wallet: string, upperEoa?: string | null): void {
		try {
			if (upperEoa) {
				migrateV1IntoWorkspace(wallet, upperEoa)
				localStorage.setItem(wsKey(wallet, upperEoa, 'parentProfile'), JSON.stringify(profile))
			} else {
				localStorage.setItem(
					globalKey('pendingParentProfile', normAddr(wallet)),
					JSON.stringify(profile),
				)
				localStorage.setItem(v1Key('parentProfile', normAddr(wallet)), JSON.stringify(profile))
			}
		} catch {
			/* ignore quota */
		}
	},

	loadInfraCard(wallet: string, upperEoa: string | null | undefined): string | null {
		try {
			if (!upperEoa) {
				return localStorage.getItem(v1Key('infra', normAddr(wallet)))
			}
			migrateV1IntoWorkspace(wallet, upperEoa)
			return localStorage.getItem(wsKey(wallet, upperEoa, 'infra'))
		} catch {
			return null
		}
	},

	saveInfraCard(wallet: string, upperEoa: string, card: string): void {
		try {
			migrateV1IntoWorkspace(wallet, upperEoa)
			localStorage.setItem(wsKey(wallet, upperEoa, 'infra'), card)
		} catch {
			/* ignore */
		}
	},

	loadPosLedger(
		wallet: string,
		upperEoa: string,
		infraCard: string,
	): PosLedgerSnapshot | null {
		try {
			migrateV1IntoWorkspace(wallet, upperEoa)
			return readJson<PosLedgerSnapshot>(
				localStorage.getItem(wsKey(wallet, upperEoa, 'ledger', normAddr(infraCard))),
			)
		} catch {
			return null
		}
	},

	savePosLedger(
		snapshot: PosLedgerSnapshot,
		wallet: string,
		upperEoa: string,
		infraCard: string,
	): void {
		try {
			localStorage.setItem(
				wsKey(wallet, upperEoa, 'ledger', normAddr(infraCard)),
				JSON.stringify(snapshot),
			)
		} catch {
			/* ignore quota */
		}
	},

	loadPermissionGranted(wallet: string, upperEoa: string | null | undefined): boolean | null {
		try {
			let v: string | null = null
			if (upperEoa) {
				migrateV1IntoWorkspace(wallet, upperEoa)
				v = localStorage.getItem(wsKey(wallet, upperEoa, 'perm'))
			}
			if (v == null) v = localStorage.getItem(v1Key('perm', normAddr(wallet)))
			if (v === '1') return true
			if (v === '0') return false
			return null
		} catch {
			return null
		}
	},

	savePermissionGranted(wallet: string, upperEoa: string, granted: boolean): void {
		try {
			migrateV1IntoWorkspace(wallet, upperEoa)
			localStorage.setItem(wsKey(wallet, upperEoa, 'perm'), granted ? '1' : '0')
		} catch {
			/* ignore */
		}
	},

	loadPointSystemEnabled(
		wallet: string,
		upperEoa: string,
		infraCard: string,
	): boolean | null {
		try {
			migrateV1IntoWorkspace(wallet, upperEoa)
			const v = localStorage.getItem(
				wsKey(wallet, upperEoa, 'pointSystem', normAddr(infraCard)),
			)
			if (v === '1') return true
			if (v === '0') return false
			return null
		} catch {
			return null
		}
	},

	savePointSystemEnabled(
		wallet: string,
		upperEoa: string,
		infraCard: string,
		enabled: boolean,
	): void {
		try {
			localStorage.setItem(
				wsKey(wallet, upperEoa, 'pointSystem', normAddr(infraCard)),
				enabled ? '1' : '0',
			)
		} catch {
			/* ignore */
		}
	},

	loadActiveCoupons(
		wallet: string,
		upperEoa: string,
		infraCard: string,
	): MerchantActiveIssuedCoupon[] | null {
		try {
			migrateV1IntoWorkspace(wallet, upperEoa)
			const raw = localStorage.getItem(
				wsKey(wallet, upperEoa, 'activeCoupons', normAddr(infraCard)),
			)
			if (!raw) return null
			const parsed = JSON.parse(raw) as unknown
			if (!Array.isArray(parsed)) return null
			return parsed as MerchantActiveIssuedCoupon[]
		} catch {
			return null
		}
	},

	saveActiveCoupons(
		wallet: string,
		upperEoa: string,
		infraCard: string,
		coupons: MerchantActiveIssuedCoupon[],
	): void {
		try {
			localStorage.setItem(
				wsKey(wallet, upperEoa, 'activeCoupons', normAddr(infraCard)),
				JSON.stringify(coupons),
			)
		} catch {
			/* ignore quota */
		}
	},

	loadOutboundJoinPending(wallet: string): PosOutboundJoinPending[] {
		try {
			const raw = localStorage.getItem(globalKey('outboundJoin', normAddr(wallet)))
			const parsed = readJson<PosOutboundJoinPending[]>(raw)
			return Array.isArray(parsed) ? parsed : []
		} catch {
			return []
		}
	},

	saveOutboundJoinPending(wallet: string, items: PosOutboundJoinPending[]): void {
		try {
			localStorage.setItem(globalKey('outboundJoin', normAddr(wallet)), JSON.stringify(items))
		} catch {
			/* ignore */
		}
	},

	appendOutboundJoinPending(wallet: string, item: PosOutboundJoinPending): void {
		const prev = posHomeTrustedCache.loadOutboundJoinPending(wallet)
		const eoa = normAddr(item.parentEoa)
		const next = [
			...prev.filter((p) => normAddr(p.parentEoa) !== eoa),
			{ ...item, parentEoa: eoa, parentTag: item.parentTag.trim() },
		]
		posHomeTrustedCache.saveOutboundJoinPending(wallet, next)
	},

	/**
	 * Drop outbound Pending join rows once the parent EOA appears as an approved
	 * workspace upper/owner (Staff approved the terminal on their program card).
	 * Returns the pruned list (trusted write only when something was removed).
	 */
	pruneOutboundJoinPendingForApprovedParents(
		wallet: string,
		approvedParentEoas: readonly string[],
	): PosOutboundJoinPending[] {
		const remove = new Set(
			approvedParentEoas.map((e) => normAddr(e)).filter((e) => Boolean(e)),
		)
		const prev = posHomeTrustedCache.loadOutboundJoinPending(wallet)
		if (remove.size === 0) return prev
		const next = prev.filter((p) => !remove.has(normAddr(p.parentEoa)))
		if (next.length !== prev.length) {
			posHomeTrustedCache.saveOutboundJoinPending(wallet, next)
		}
		return next
	},
}

/** Prefixes scanned by wallet-recover gate for registeredTag keys. */
export const POS_REGISTERED_TAG_LS_PREFIXES = [
	`${PREFIX_V2}:registeredTag:`,
	`${PREFIX_V1}:registeredTag:`,
] as const
