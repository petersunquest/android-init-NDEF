import type { NfcTopupCurrencySplit } from '@/utils/topupCurrencySplit'
import {
	formatTopupApiAmount2dp,
	nfcTopupCurrencySplitAllCard,
	nfcTopupCurrencySplitFromPosKeypad,
	nfcTopupCurrencySplitWithProgramRechargeBonus,
} from '@/utils/topupCurrencySplit'
import type { TopupPaymentMethodRaw } from '@/utils/topupPaymentMethod'
import {
	computeProgramRechargeBonus,
	parseRechargeBonusRulesFromMetadata,
	selectProgramRechargeBonusRule,
	type RechargeBonusRule,
} from '@/utils/programTopupPromotion'

export type { RechargeBonusRule }

export { parseRechargeBonusRulesFromMetadata, selectProgramRechargeBonusRule, computeProgramRechargeBonus }

export interface TopupAmountSplitInput {
	keypadAmount: string
	methodRaw: TopupPaymentMethodRaw
	bonusExpanded: boolean
	bonusRatePercent: number
	programRules: RechargeBonusRule[]
}

export function resolveTopupApiAmountAndSplit(input: TopupAmountSplitInput): {
	apiAmount: string
	split: NfcTopupCurrencySplit | null
	programBonus: number
} {
	const amt = input.keypadAmount.trim().replace(/,/g, '')
	const defaultSplit = nfcTopupCurrencySplitFromPosKeypad(
		amt,
		input.methodRaw,
		input.bonusExpanded,
		input.bonusRatePercent,
	)
	if (input.methodRaw === 'bonus' || input.bonusExpanded) {
		return { apiAmount: amt, split: defaultSplit, programBonus: 0 }
	}
	const principal = Number(amt)
	const rule = selectProgramRechargeBonusRule(input.programRules, principal)
	if (!rule) {
		return { apiAmount: amt, split: defaultSplit, programBonus: 0 }
	}
	const programBonus = computeProgramRechargeBonus(rule, principal)
	if (programBonus < 1e-9) {
		return { apiAmount: amt, split: defaultSplit, programBonus: 0 }
	}
	const total = principal + programBonus
	const api = formatTopupApiAmount2dp(total)
	const split =
		nfcTopupCurrencySplitWithProgramRechargeBonus(amt, programBonus, input.methodRaw) ??
		nfcTopupCurrencySplitFromPosKeypad(api, input.methodRaw, false, 0) ??
		nfcTopupCurrencySplitAllCard(api)
	return { apiAmount: api, split, programBonus }
}
