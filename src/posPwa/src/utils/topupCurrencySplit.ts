export interface NfcTopupCurrencySplit {
	currencyAmount: string
	cardCurrencyAmount: string
	cashCurrencyAmount: string
	bonusCurrencyAmount: string
}

function decimalRound6(n: number): number {
	return Math.round(n * 1e6) / 1e6
}

function formatDecimalTopupApi6(n: number): string {
	const rounded = decimalRound6(n)
	const s = rounded.toFixed(6).replace(/\.?0+$/, '')
	return s || '0'
}

/** POS keypad split — mirrors iOS `BeamioAPIClient.nfcTopupCurrencySplitFromPosKeypad`. */
export function nfcTopupCurrencySplitFromPosKeypad(
	keypadAmount: string,
	methodRaw: string,
	bonusExpanded: boolean,
	selectedBonusRate: number,
): NfcTopupCurrencySplit | null {
	const raw = keypadAmount.trim().replace(/,/g, '')
	const base = Number(raw)
	if (!Number.isFinite(base) || base <= 0) return null
	const z = formatDecimalTopupApi6(0)
	switch (methodRaw) {
		case 'creditCard':
		case 'usdc':
		case 'cadd':
			if (bonusExpanded) {
				const rate = selectedBonusRate / 100
				const bonusPart = decimalRound6(base * rate)
				const total = decimalRound6(base + bonusPart)
				const baseR = decimalRound6(base)
				const bonusR = decimalRound6(total - baseR)
				return {
					currencyAmount: formatDecimalTopupApi6(total),
					cardCurrencyAmount: formatDecimalTopupApi6(baseR),
					cashCurrencyAmount: z,
					bonusCurrencyAmount: formatDecimalTopupApi6(bonusR),
				}
			}
			{
				const c = formatDecimalTopupApi6(base)
				return {
					currencyAmount: c,
					cardCurrencyAmount: c,
					cashCurrencyAmount: z,
					bonusCurrencyAmount: z,
				}
			}
		case 'cash':
			if (bonusExpanded) {
				const rate = selectedBonusRate / 100
				const bonusPart = decimalRound6(base * rate)
				const total = decimalRound6(base + bonusPart)
				const baseR = decimalRound6(base)
				const bonusR = decimalRound6(total - baseR)
				return {
					currencyAmount: formatDecimalTopupApi6(total),
					cardCurrencyAmount: z,
					cashCurrencyAmount: formatDecimalTopupApi6(baseR),
					bonusCurrencyAmount: formatDecimalTopupApi6(bonusR),
				}
			}
			{
				const c = formatDecimalTopupApi6(base)
				return {
					currencyAmount: c,
					cardCurrencyAmount: z,
					cashCurrencyAmount: c,
					bonusCurrencyAmount: z,
				}
			}
		case 'bonus': {
			const b = formatDecimalTopupApi6(base)
			return {
				currencyAmount: b,
				cardCurrencyAmount: z,
				cashCurrencyAmount: z,
				bonusCurrencyAmount: b,
			}
		}
		default:
			return null
	}
}

export function nfcTopupCurrencySplitAllCard(amount: string): NfcTopupCurrencySplit | null {
	return nfcTopupCurrencySplitFromPosKeypad(amount, 'creditCard', false, 0)
}

export function nfcTopupCurrencySplitWithProgramRechargeBonus(
	principalAmount: string,
	programBonus: number,
	methodRaw: string,
): NfcTopupCurrencySplit | null {
	const raw = principalAmount.trim().replace(/,/g, '')
	const principal = Number(raw)
	if (!Number.isFinite(principal) || principal <= 0 || programBonus <= 0) return null
	const total = decimalRound6(principal + programBonus)
	const pR = formatDecimalTopupApi6(decimalRound6(principal))
	const bR = formatDecimalTopupApi6(decimalRound6(programBonus))
	const tR = formatDecimalTopupApi6(total)
	const z = formatDecimalTopupApi6(0)
	switch (methodRaw) {
		case 'creditCard':
		case 'usdc':
		case 'cadd':
			return {
				currencyAmount: tR,
				cardCurrencyAmount: pR,
				cashCurrencyAmount: z,
				bonusCurrencyAmount: bR,
			}
		case 'cash':
			return {
				currencyAmount: tR,
				cardCurrencyAmount: z,
				cashCurrencyAmount: pR,
				bonusCurrencyAmount: bR,
			}
		default:
			return null
	}
}

export function formatTopupApiAmount2dp(n: number): string {
	return ((Math.round(n * 100) / 100).toFixed(2))
}
