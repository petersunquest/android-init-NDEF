import type { PosNativeAction } from '@/types/pos'

export const POS_HOME_ROUTES = {
	home: '/home',
	checkBalance: '/check-balance',
	topUp: '/topup',
	charge: '/charge',
	deductPoints: '/deduct-points',
	transactions: '/transactions',
	activeCoupons: '/active-coupons',
	workspace: '/workspace',
	nativeAction: (action: PosNativeAction) => `/native/${action}`,
} as const

/** BootRouter home phase + user may stay on these paths during in-flight actions. */
export function isPosHomePhasePath(path: string): boolean {
	if (
		path === POS_HOME_ROUTES.home ||
		path === POS_HOME_ROUTES.checkBalance ||
		path === POS_HOME_ROUTES.topUp ||
		path === POS_HOME_ROUTES.charge ||
		path === POS_HOME_ROUTES.deductPoints ||
		path === POS_HOME_ROUTES.transactions ||
		path === POS_HOME_ROUTES.activeCoupons ||
		path === POS_HOME_ROUTES.workspace
	) {
		return true
	}
	return path.startsWith('/native/')
}

export const NATIVE_ACTION_LOADING: Record<
	PosNativeAction,
	{ title: string; subtitle: string }
> = {
	charge: {
		title: 'Charge',
		subtitle: 'Opening payment…',
	},
	topup: {
		title: 'Top-up',
		subtitle: 'Opening top-up…',
	},
	readBalance: {
		title: 'Check Balance',
		subtitle: 'Opening balance check…',
	},
	deductPoints: {
		title: 'Deduct Points',
		subtitle: 'Opening deduct points…',
	},
	history: {
		title: 'History',
		subtitle: 'Opening history…',
	},
	linkApp: {
		title: 'Link App',
		subtitle: 'Opening link app…',
	},
	activeCoupons: {
		title: 'Active Coupons',
		subtitle: 'Opening coupons…',
	},
}

export function parseNativeActionParam(raw: string | undefined): PosNativeAction | null {
	if (!raw) return null
	return raw in NATIVE_ACTION_LOADING ? (raw as PosNativeAction) : null
}
