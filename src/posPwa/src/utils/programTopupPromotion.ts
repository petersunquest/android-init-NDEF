export type TopupPromotionRewardType = 'percent' | 'fixed'

export type TopupPromotionMetadata = {
	enabled?: boolean
	validFrom?: string
	validTo?: string
	minimumTopupAmount: number
	rewardType: TopupPromotionRewardType
	rewardValue: number
}

export type RechargeBonusRule = {
	paymentAmount: number
	bonusValue: number
	bonusProportional: boolean
}

function parseAmount(raw: unknown): number | null {
	if (raw == null || raw === '') return null
	const n = typeof raw === 'number' ? raw : Number.parseFloat(String(raw).replace(/,/g, '').trim())
	if (!Number.isFinite(n) || n <= 0) return null
	return Math.round(n * 100) / 100
}

function parseYmd(raw: unknown): string | undefined {
	if (typeof raw !== 'string') return undefined
	const t = raw.trim()
	if (!/^\d{4}-\d{2}-\d{2}$/.test(t)) return undefined
	return t
}

function approxEq(a: number, b: number): boolean {
	return Math.abs(a - b) < 0.005
}

export function formatLocalYmd(d: Date = new Date()): string {
	const y = d.getFullYear()
	const m = String(d.getMonth() + 1).padStart(2, '0')
	const day = String(d.getDate()).padStart(2, '0')
	return `${y}-${m}-${day}`
}

export function isTopupPromotionActive(
	promo: TopupPromotionMetadata | null | undefined,
	now: Date = new Date(),
): boolean {
	if (!promo || promo.enabled === false) return false
	const min = parseAmount(promo.minimumTopupAmount)
	const reward = parseAmount(promo.rewardValue)
	if (min == null || reward == null) return false
	const today = formatLocalYmd(now)
	const from = parseYmd(promo.validFrom)
	const to = parseYmd(promo.validTo)
	if (from && today < from) return false
	if (to && today > to) return false
	return true
}

function parseOneLegacyRule(row: unknown): RechargeBonusRule | null {
	if (!row || typeof row !== 'object') return null
	const o = row as Record<string, unknown>
	const pay = Number(o.paymentAmount ?? o.payment_amount)
	const bonus = Number(o.bonusValue ?? o.bonus_value)
	const prop = Boolean(o.bonusProportional ?? o.bonus_proportional)
	if (!Number.isFinite(pay) || !Number.isFinite(bonus) || pay <= 0) return null
	return { paymentAmount: pay, bonusValue: bonus, bonusProportional: prop }
}

/**
 * Heal legacy buggy encode: percent + unscaled bonusValue === rewardValue → fixed.
 */
function healTopupPromotionRewardType(
	promo: TopupPromotionMetadata,
	legacyBonus?: RechargeBonusRule | null,
): TopupPromotionMetadata {
	if (promo.rewardType !== 'percent') return promo
	const min = promo.minimumTopupAmount
	const reward = promo.rewardValue
	const scaled = Math.round(min * reward) / 100
	if (!legacyBonus) return promo
	const bv = legacyBonus.bonusValue
	if (!legacyBonus.bonusProportional && approxEq(bv, reward)) {
		return { ...promo, rewardType: 'fixed' }
	}
	if (legacyBonus.bonusProportional && approxEq(bv, reward) && !approxEq(bv, scaled)) {
		return { ...promo, rewardType: 'fixed' }
	}
	return promo
}

function normalizeTopupPromotion(raw: Record<string, unknown>): TopupPromotionMetadata | null {
	const min = parseAmount(raw.minimumTopupAmount ?? raw.minimum_topup_amount)
	const reward = parseAmount(raw.rewardValue ?? raw.reward_value)
	if (min == null || reward == null) return null
	const rewardTypeRaw = String(raw.rewardType ?? raw.reward_type ?? '').trim().toLowerCase()
	// Missing / unknown → fixed (not percent).
	const rewardType: TopupPromotionRewardType =
		rewardTypeRaw === 'percent' ? 'percent' : 'fixed'
	return {
		enabled: raw.enabled === false ? false : true,
		validFrom: parseYmd(raw.validFrom ?? raw.valid_from),
		validTo: parseYmd(raw.validTo ?? raw.valid_to),
		minimumTopupAmount: min,
		rewardType,
		rewardValue: reward,
	}
}

/**
 * Canonical → POS recharge rule.
 * - fixed: flat bonusValue
 * - percent: bonusValue = paymentAmount * rewardValue / 100, proportional
 */
export function topupPromotionToRechargeBonusRule(
	promo: TopupPromotionMetadata,
): RechargeBonusRule | null {
	if (!isTopupPromotionActive(promo)) return null
	if (promo.rewardType === 'percent') {
		const bonusValue = Math.round(promo.minimumTopupAmount * promo.rewardValue) / 100
		if (bonusValue <= 0) return null
		return {
			paymentAmount: promo.minimumTopupAmount,
			bonusValue,
			bonusProportional: true,
		}
	}
	return {
		paymentAmount: promo.minimumTopupAmount,
		bonusValue: promo.rewardValue,
		bonusProportional: false,
	}
}

function firstLegacyBonus(meta: Record<string, unknown>): RechargeBonusRule | null {
	const raw = meta.bonusRules ?? meta.bonusRule
	if (Array.isArray(raw)) return parseOneLegacyRule(raw[0])
	return parseOneLegacyRule(raw)
}

export function parseTopupPromotionFromMetadata(
	meta: Record<string, unknown> | null | undefined,
): TopupPromotionMetadata | null {
	if (!meta) return null
	const legacyRoot = firstLegacyBonus(meta)
	const stm = meta.shareTokenMetadata
	const legacyStm =
		stm && typeof stm === 'object' ? firstLegacyBonus(stm as Record<string, unknown>) : null
	const legacy = legacyRoot ?? legacyStm

	const direct = meta.topupPromotion
	if (direct && typeof direct === 'object') {
		const normalized = normalizeTopupPromotion(direct as Record<string, unknown>)
		return normalized ? healTopupPromotionRewardType(normalized, legacy) : null
	}
	if (stm && typeof stm === 'object') {
		const nested = (stm as Record<string, unknown>).topupPromotion
		if (nested && typeof nested === 'object') {
			const normalized = normalizeTopupPromotion(nested as Record<string, unknown>)
			return normalized ? healTopupPromotionRewardType(normalized, legacy) : null
		}
	}
	return null
}

function parseLegacyBonusRulesFromRecord(
	rec: Record<string, unknown> | null | undefined,
): RechargeBonusRule[] {
	if (!rec) return []
	const raw = rec.bonusRules ?? rec.bonusRule
	if (!Array.isArray(raw)) {
		const one = parseOneLegacyRule(raw)
		return one ? [one] : []
	}
	return raw.map(parseOneLegacyRule).filter(Boolean) as RechargeBonusRule[]
}

export function parseRechargeBonusRulesFromMetadata(
	meta: Record<string, unknown> | null | undefined,
): RechargeBonusRule[] {
	if (!meta) return []
	const promo = parseTopupPromotionFromMetadata(meta)
	if (promo) {
		const rule = topupPromotionToRechargeBonusRule(promo)
		return rule ? [rule] : []
	}
	const rootRules = parseLegacyBonusRulesFromRecord(meta)
	if (rootRules.length > 0) return rootRules
	const stm = meta.shareTokenMetadata
	if (stm && typeof stm === 'object') {
		return parseLegacyBonusRulesFromRecord(stm as Record<string, unknown>)
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

export function computeProgramRechargeBonus(rule: RechargeBonusRule, principal: number): number {
	if (rule.bonusProportional) {
		if (rule.paymentAmount <= 1e-9) return 0
		const raw = (principal * rule.bonusValue) / rule.paymentAmount
		return Math.round(raw * 100) / 100
	}
	return rule.bonusValue
}
