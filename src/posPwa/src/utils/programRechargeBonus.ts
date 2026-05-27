import type { NfcTopupCurrencySplit } from '@/utils/topupCurrencySplit'
import {
	formatTopupApiAmount2dp,
	nfcTopupCurrencySplitAllCard,
	nfcTopupCurrencySplitFromPosKeypad,
	nfcTopupCurrencySplitWithProgramRechargeBonus,
} from '@/utils/topupCurrencySplit'
import type { TopupPaymentMethodRaw } from '@/utils/topupPaymentMethod'

export interface RechargeBonusRule {
	paymentAmount: number
	bonusValue: number
	bonusProportional: boolean
}

function parseOneRule(row: unknown): RechargeBonusRule | null {
	if (!row || typeof row !== 'object') return null
	const o = row as Record<string, unknown>
	const pay = Number(o.paymentAmount ?? o.payment_amount)
	const bonus = Number(o.bonusValue ?? o.bonus_value)
	const prop = Boolean(o.bonusProportional ?? o.bonus_proportional)
	if (!Number.isFinite(pay) || !Number.isFinite(bonus) || pay <= 0) return null
	return { paymentAmount: pay, bonusValue: bonus, bonusProportional: prop }
}

function parseRulesDirect(meta: Record<string, unknown>): RechargeBonusRule[] {
	const raw = meta.bonusRules ?? meta.bonusRule
	if (!Array.isArray(raw)) return []
	return raw.map(parseOneRule).filter(Boolean) as RechargeBonusRule[]
}

export function parseRechargeBonusRulesFromMetadata(
	meta: Record<string, unknown> | null | undefined,
): RechargeBonusRule[] {
	if (!meta) return []
	let rules = parseRulesDirect(meta)
	if (rules.length) return rules
	const stm = meta.shareTokenMetadata
	if (stm && typeof stm === 'object') {
		rules = parseRulesDirect(stm as Record<string, unknown>)
		if (rules.length) return rules
	}
	return []
}

export function selectProgramRechargeBonusRule(
	rules: RechargeBonusRule[],
	paymentPrincipal: number,
): RechargeBonusRule | null {
	if (paymentPrincipal <= 0 || !rules.length) return null
	const pay = Math.round(paymentPrincipal * 100) / 100
	const qualifying = rules.filter((r) => {
		const threshold = Math.round(r.paymentAmount * 100) / 100
		return pay + 1e-6 >= threshold
	})
	if (!qualifying.length) return null
	return qualifying.reduce((best, r) => (r.paymentAmount > best.paymentAmount ? r : best))
}

export function computeProgramRechargeBonus(
	rule: RechargeBonusRule,
	principal: number,
): number {
	if (rule.bonusProportional) {
		if (rule.paymentAmount <= 1e-9) return 0
		const raw = (principal * rule.bonusValue) / rule.paymentAmount
		return Math.round(raw * 100) / 100
	}
	return rule.bonusValue
}

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
