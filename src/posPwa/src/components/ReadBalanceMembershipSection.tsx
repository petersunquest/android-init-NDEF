import { membershipDurationLabel, membershipFeeE6ToHuman } from '@/utils/beamioPaymentRouting'
import type { ReadBalanceMembershipTierChoice } from '@/utils/readBalanceMembership'

/** Join / Upgrade membership tiers on Check Balance result. */
export function ReadBalanceMembershipSection({
	mode,
	tiers,
	currencyPrefix,
	disabled,
	onSelectTier,
}: {
	mode: 'join' | 'upgrade'
	tiers: ReadBalanceMembershipTierChoice[]
	currencyPrefix: string
	disabled?: boolean
	onSelectTier: (tier: ReadBalanceMembershipTierChoice) => void
}) {
	if (tiers.length === 0) return null

	const title = mode === 'upgrade' ? 'Upgrade membership' : 'Join membership'
	const hint =
		mode === 'upgrade'
			? 'Select a higher tier, then scan the member NFC or QR to collect the membership fee.'
			: 'Select a tier, then scan the member NFC or QR to collect the membership fee and issue the card.'

	return (
		<section className="rounded-2xl bg-white p-4 shadow-sm">
			<p className="text-xs font-semibold uppercase tracking-wide text-slate-500">{title}</p>
			<p className="mt-1 text-sm text-slate-600">{hint}</p>
			<div className="mt-3 flex flex-col gap-2">
				{tiers.map((t) => {
					const feeLabel = membershipFeeE6ToHuman(t.feeFiat6) || '0'
					const dur = membershipDurationLabel(t.durationKind)
					return (
						<button
							key={t.tierIndex}
							type="button"
							disabled={disabled}
							onClick={() => onSelectTier(t)}
							className="flex items-center justify-between gap-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-3 text-left transition active:scale-[0.99] disabled:opacity-45"
						>
							<span className="min-w-0">
								<span className="block text-sm font-semibold text-slate-900">{t.name}</span>
								{dur ? (
									<span className="mt-0.5 block text-[11px] font-medium text-slate-500">
										{dur}
									</span>
								) : null}
							</span>
							<span className="shrink-0 text-sm font-bold tabular-nums text-[#7C3AED]">
								{currencyPrefix}
								{feeLabel}
							</span>
						</button>
					)
				})}
			</div>
		</section>
	)
}
