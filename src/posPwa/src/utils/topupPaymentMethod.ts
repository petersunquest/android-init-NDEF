export type TopupPaymentMethodRaw = 'creditCard' | 'usdc' | 'cadd' | 'cash' | 'bonus'

export interface PosTerminalTopupPolicy {
	allowTopupBankCard: boolean
	allowTopupUsdc: boolean
	allowTopupCadd: boolean
	allowTopupCash: boolean
	allowTopupAirdrop: boolean
}

export const POS_TERMINAL_TOPUP_POLICY_ALL: PosTerminalTopupPolicy = {
	allowTopupBankCard: true,
	allowTopupUsdc: true,
	allowTopupCadd: true,
	allowTopupCash: true,
	allowTopupAirdrop: true,
}

export const TOPUP_METHOD_CYCLE_ORDER: TopupPaymentMethodRaw[] = [
	'creditCard',
	'usdc',
	'cadd',
	'cash',
	'bonus',
]

export const TOPUP_METHOD_LABEL: Record<TopupPaymentMethodRaw, string> = {
	creditCard: 'Card',
	usdc: 'USDC',
	cadd: 'CADD',
	cash: 'Cash',
	bonus: 'Bonus',
}

export const TOPUP_LAST_METHOD_STORAGE_KEY = 'pos.topup.lastPaymentMethod'

export function topupMethodAllowed(
	method: TopupPaymentMethodRaw,
	policy: PosTerminalTopupPolicy,
): boolean {
	switch (method) {
		case 'creditCard':
			return policy.allowTopupBankCard
		case 'usdc':
			return policy.allowTopupUsdc
		case 'cadd':
			return policy.allowTopupCadd
		case 'cash':
			return policy.allowTopupCash
		case 'bonus':
			return policy.allowTopupAirdrop
		default:
			return false
	}
}

export function allowedTopupMethods(policy: PosTerminalTopupPolicy): TopupPaymentMethodRaw[] {
	return TOPUP_METHOD_CYCLE_ORDER.filter((m) => topupMethodAllowed(m, policy))
}

export function isExternalWalletStablecoinMethod(raw: string): boolean {
	const n = raw.trim().toLowerCase()
	return n === 'usdc' || n === 'cadd'
}

export function stablecoinSymbolForMethod(raw: string): 'USDC' | 'CADD' {
	return raw.trim().toLowerCase() === 'cadd' ? 'CADD' : 'USDC'
}

export function paymentTokenQueryValue(raw: string): string | undefined {
	const n = raw.trim().toLowerCase()
	if (n === 'cadd') return 'CADD'
	if (n === 'usdc') return 'USDC'
	return undefined
}

export function loadPersistedTopupMethod(): TopupPaymentMethodRaw {
	try {
		const raw = localStorage.getItem(TOPUP_LAST_METHOD_STORAGE_KEY)
		if (raw && TOPUP_METHOD_CYCLE_ORDER.includes(raw as TopupPaymentMethodRaw)) {
			return raw as TopupPaymentMethodRaw
		}
	} catch {
		/* ignore */
	}
	return 'creditCard'
}

export function savePersistedTopupMethod(method: TopupPaymentMethodRaw): void {
	try {
		localStorage.setItem(TOPUP_LAST_METHOD_STORAGE_KEY, method)
	} catch {
		/* ignore */
	}
}
