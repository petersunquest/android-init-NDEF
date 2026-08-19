import {
	Banknote,
	CreditCard,
	Sparkles,
	Wallet,
} from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { BeamioAmountPad, formatAmountPadDisplay } from '@/components/BeamioAmountPad'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { UsdcBaseCompositeIcon } from '@/components/ChainTokenCompositeIcon'
import { nfcTopupCurrencySplitFromPosKeypad } from '@/utils/topupCurrencySplit'
import {
	allowedTopupMethods,
	loadPersistedTopupMethod,
	savePersistedTopupMethod,
	TOPUP_METHOD_LABEL,
	type TopupPaymentMethodRaw,
	type PosTerminalTopupPolicy,
	POS_TERMINAL_TOPUP_POLICY_ALL,
} from '@/utils/topupPaymentMethod'
import {
	membershipDurationLabel,
	membershipFeeE6ToHuman,
	metadataTierMembershipFeeE6,
	metadataTierOnChainIndex,
	type MetadataTierRow,
} from '@/utils/beamioPaymentRouting'
import { membershipPurchaseApiAmountHuman } from '@/utils/readBalanceMembership'

const TOPUP_PURPLE = '#7C3AED'
const METHOD_ACCENT: Record<TopupPaymentMethodRaw, string> = {
	creditCard: '#D49B1F',
	usdc: '#2775CA',
	cadd: '#E53A2F',
	cash: '#6B7280',
	bonus: '#EC4899',
}

function methodIcon(method: TopupPaymentMethodRaw) {
	switch (method) {
		case 'creditCard':
			return CreditCard
		case 'cash':
			return Banknote
		case 'bonus':
			return Sparkles
		default:
			return Wallet
	}
}

export type TopupMembershipTierChoice = {
	tierIndex: number
	feeFiat6: string
	minUsdc6?: string
	name: string
	durationKind?: number
}

export function TopupAmountPadPage({
	policy = POS_TERMINAL_TOPUP_POLICY_ALL,
	membershipFeeMode = false,
	membershipTiers = [],
	cardCurrencyPrefix = '$',
	onCancel,
	onContinue,
}: {
	policy?: PosTerminalTopupPolicy
	/** Card metadata: any tier fee > 0 — force tier picker; amount ≥ fee. */
	membershipFeeMode?: boolean
	membershipTiers?: MetadataTierRow[]
	cardCurrencyPrefix?: string
	onCancel: () => void
	onContinue: (input: {
		method: TopupPaymentMethodRaw
		keypadAmount: string
		currencyAmount: string
		membershipTierIndex?: number
		membershipFeeFiat6?: string
	}) => void
}) {
	const allowed = useMemo(() => allowedTopupMethods(policy), [policy])
	const feeTiers = useMemo(() => {
		if (!membershipFeeMode) return [] as TopupMembershipTierChoice[]
		const out: TopupMembershipTierChoice[] = []
		membershipTiers.forEach((row, i) => {
			const feeFiat6 = metadataTierMembershipFeeE6(row)
			if (BigInt(feeFiat6) <= 0n) return
			out.push({
				tierIndex: metadataTierOnChainIndex(row, i),
				feeFiat6,
				minUsdc6: row.minUsdc6,
				name: (row.name ?? `Tier ${i + 1}`).trim() || `Tier ${i + 1}`,
				durationKind: row.membershipDurationKind,
			})
		})
		return out
	}, [membershipFeeMode, membershipTiers])

	const [selectedTierKey, setSelectedTierKey] = useState(() =>
		feeTiers[0] ? `${feeTiers[0].tierIndex}` : '',
	)
	const selectedTier = useMemo(
		() => feeTiers.find((t) => `${t.tierIndex}` === selectedTierKey) ?? feeTiers[0],
		[feeTiers, selectedTierKey],
	)

	const [method, setMethod] = useState<TopupPaymentMethodRaw>(() => {
		const saved = loadPersistedTopupMethod()
		return allowed.includes(saved) ? saved : (allowed[0] ?? 'creditCard')
	})
	const [amount, setAmount] = useState('0')

	useEffect(() => {
		if (!selectedTier) return
		/* Amount = fee + tier minUsdc6 so Cluster can credit that floor after membership fee. */
		const human = membershipPurchaseApiAmountHuman(selectedTier.feeFiat6, selectedTier.minUsdc6)
		if (human) setAmount(human)
	}, [selectedTier?.tierIndex, selectedTier?.feeFiat6, selectedTier?.minUsdc6])

	useEffect(() => {
		if (feeTiers.length && !feeTiers.some((t) => `${t.tierIndex}` === selectedTierKey)) {
			setSelectedTierKey(`${feeTiers[0].tierIndex}`)
		}
	}, [feeTiers, selectedTierKey])

	const nextMethod = useMemo(() => {
		if (!allowed.length) return method
		const idx = allowed.indexOf(method)
		return allowed[(idx + 1) % allowed.length]
	}, [allowed, method])

	const parsed = Number(amount)
	const feeHuman = selectedTier ? Number(membershipFeeE6ToHuman(selectedTier.feeFiat6) || '0') : 0
	const needsMembershipPick = membershipFeeMode && feeTiers.length > 0
	const amountMeetsFee =
		!needsMembershipPick || (Number.isFinite(parsed) && parsed + 1e-9 >= feeHuman)
	const canContinue =
		allowed.length > 0 &&
		Number.isFinite(parsed) &&
		parsed > 0 &&
		(!needsMembershipPick || Boolean(selectedTier)) &&
		amountMeetsFee
	const accent = method === 'bonus' ? METHOD_ACCENT.bonus : TOPUP_PURPLE
	const balanceCredit =
		needsMembershipPick && Number.isFinite(parsed) && parsed >= feeHuman
			? Math.max(0, parsed - feeHuman)
			: null

	return (
		<PosScreenShell bg="bg-[#F9F9FE]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onCancel}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="px-4 pb-[max(1rem,env(safe-area-inset-bottom))] pt-14">
					<div className="flex min-h-0 flex-1 flex-col gap-3">
						<div className="shrink-0 rounded-2xl bg-white p-4 shadow-sm">
							<div className="flex items-center gap-3">
								<div className="min-w-0 flex-1">
									<div className="flex items-baseline gap-1">
										<span
											className="text-3xl font-bold"
											style={{ color: accent }}
										>
											{cardCurrencyPrefix}
										</span>
										<span
											className="truncate text-5xl font-black tabular-nums"
											style={{ color: accent }}
										>
											{formatAmountPadDisplay(amount)}
										</span>
									</div>
								</div>
								<button
									type="button"
									onClick={() => {
										if (allowed.length <= 1) return
										setMethod(nextMethod)
										savePersistedTopupMethod(nextMethod)
									}}
									className="flex shrink-0 flex-col items-center gap-2"
									aria-label={`Payment method ${TOPUP_METHOD_LABEL[method]}. Tap to switch`}
								>
									<span
										className="text-xs font-semibold"
										style={{ color: METHOD_ACCENT[method] }}
									>
										{TOPUP_METHOD_LABEL[method]}
									</span>
									<span
										className="flex h-11 w-11 items-center justify-center rounded-full"
										style={{ backgroundColor: `${METHOD_ACCENT[method]}24` }}
									>
										{method === 'usdc' ? (
											<UsdcBaseCompositeIcon size={22} />
										) : (
											(() => {
												const Icon = methodIcon(method)
												return (
													<Icon
														className="h-5 w-5"
														style={{ color: METHOD_ACCENT[method] }}
													/>
												)
											})()
										)}
									</span>
								</button>
							</div>
						</div>

						{needsMembershipPick ? (
							<div className="shrink-0 space-y-2 rounded-2xl bg-white p-3 shadow-sm">
								<p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
									Membership tier
								</p>
								<div className="flex flex-wrap gap-2">
									{feeTiers.map((t) => {
										const active = selectedTier?.tierIndex === t.tierIndex
										const feeLabel = membershipFeeE6ToHuman(t.feeFiat6) || '0'
										const dur = membershipDurationLabel(t.durationKind)
										return (
											<button
												key={t.tierIndex}
												type="button"
												onClick={() => setSelectedTierKey(`${t.tierIndex}`)}
												className={`rounded-xl px-3 py-2 text-left text-sm font-semibold transition ${
													active
														? 'bg-[#7C3AED] text-white'
														: 'bg-slate-100 text-slate-700'
												}`}
											>
												<span className="block">{t.name}</span>
												<span
													className={`block text-[11px] font-medium ${
														active ? 'text-white/85' : 'text-slate-500'
													}`}
												>
													{cardCurrencyPrefix}
													{feeLabel}
													{dur ? ` · ${dur}` : ''}
												</span>
											</button>
										)
									})}
								</div>
								{selectedTier ? (
									<div className="space-y-1 border-t border-slate-100 pt-2 text-sm">
										<div className="flex justify-between gap-2 text-slate-600">
											<span>Membership fee</span>
											<span className="font-semibold tabular-nums text-slate-900">
												{cardCurrencyPrefix}
												{membershipFeeE6ToHuman(selectedTier.feeFiat6) || '0'}
											</span>
										</div>
										{balanceCredit != null ? (
											<div className="flex justify-between gap-2 text-slate-600">
												<span>Balance credit</span>
												<span className="font-semibold tabular-nums text-slate-900">
													{cardCurrencyPrefix}
													{Number.isInteger(balanceCredit)
														? String(balanceCredit)
														: balanceCredit.toFixed(2)}
												</span>
											</div>
										) : null}
										{!amountMeetsFee ? (
											<p className="text-xs font-medium text-amber-600">
												Amount must be at least the membership fee.
											</p>
										) : null}
									</div>
								) : null}
							</div>
						) : null}

						{allowed.length === 0 ? (
							<p className="shrink-0 text-sm font-medium text-slate-600">
								No top-up methods are enabled for this terminal. Ask the merchant to
								update device settings.
							</p>
						) : null}

						<BeamioAmountPad amount={amount} onAmountChange={setAmount} />

						<button
							type="button"
							disabled={!canContinue}
							onClick={() => {
								const split = nfcTopupCurrencySplitFromPosKeypad(
									amount,
									method,
									false,
									20,
								)
								if (!split) return
								savePersistedTopupMethod(method)
								onContinue({
									method,
									keypadAmount: amount,
									currencyAmount: split.currencyAmount,
									...(needsMembershipPick && selectedTier
										? {
												membershipTierIndex: selectedTier.tierIndex,
												membershipFeeFiat6: selectedTier.feeFiat6,
											}
										: {}),
								})
							}}
							className="shrink-0 rounded-xl py-4 text-lg font-semibold text-white disabled:opacity-45"
							style={{ backgroundColor: TOPUP_PURPLE }}
						>
							Confirm Top-Up
						</button>
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
