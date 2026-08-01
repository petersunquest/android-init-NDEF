export type ChargePaymentMethodRaw = 'nfcCard' | 'usdc' | 'cadd'

/** Persisted UI option key (iOS `ChargePaymentMethodOption`). */
export type ChargePaymentMethodOption = 'credit' | 'usdc' | 'cadd'

export interface PosTerminalChargePolicy {
	allowPayerUsdcInCharge: boolean
	allowPayerCaddInCharge: boolean
}

export const POS_TERMINAL_CHARGE_POLICY_ALL: PosTerminalChargePolicy = {
	allowPayerUsdcInCharge: true,
	allowPayerCaddInCharge: true,
}

export const CHARGE_METHOD_CYCLE_ORDER: ChargePaymentMethodOption[] = ['credit', 'usdc', 'cadd']

export const CHARGE_METHOD_LABEL: Record<ChargePaymentMethodOption, string> = {
	credit: 'Program Card',
	usdc: 'USDC',
	cadd: 'CADD',
}

export const CHARGE_LAST_METHOD_STORAGE_KEY = 'pos.charge.lastPaymentMethod'

export function chargeMethodAllowed(
	method: ChargePaymentMethodOption,
	policy: PosTerminalChargePolicy,
): boolean {
	switch (method) {
		case 'credit':
			return true
		case 'usdc':
			return policy.allowPayerUsdcInCharge
		case 'cadd':
			return policy.allowPayerCaddInCharge
		default:
			return false
	}
}

export function allowedChargeMethods(policy: PosTerminalChargePolicy): ChargePaymentMethodOption[] {
	return CHARGE_METHOD_CYCLE_ORDER.filter((m) => chargeMethodAllowed(m, policy))
}

export function chargeOptionToMethodRaw(option: ChargePaymentMethodOption): ChargePaymentMethodRaw {
	switch (option) {
		case 'usdc':
			return 'usdc'
		case 'cadd':
			return 'cadd'
		case 'credit':
		default:
			return 'nfcCard'
	}
}

export function chargeMethodRawToOption(raw: ChargePaymentMethodRaw): ChargePaymentMethodOption {
	switch (raw) {
		case 'usdc':
			return 'usdc'
		case 'cadd':
			return 'cadd'
		case 'nfcCard':
		default:
			return 'credit'
	}
}

export function loadPersistedChargeMethod(): ChargePaymentMethodOption {
	try {
		const raw = localStorage.getItem(CHARGE_LAST_METHOD_STORAGE_KEY)
		if (raw && CHARGE_METHOD_CYCLE_ORDER.includes(raw as ChargePaymentMethodOption)) {
			return raw as ChargePaymentMethodOption
		}
	} catch {
		/* ignore */
	}
	return 'credit'
}

export function savePersistedChargeMethod(method: ChargePaymentMethodOption): void {
	try {
		localStorage.setItem(CHARGE_LAST_METHOD_STORAGE_KEY, method)
	} catch {
		/* ignore */
	}
}
