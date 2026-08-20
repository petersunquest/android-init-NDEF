import { useState } from 'react'
import { membershipDurationLabel, membershipFeeE6ToHuman } from '@/utils/beamioPaymentRouting'
import type { ReadBalanceMembershipTierChoice } from '@/utils/readBalanceMembership'
import type { TopupPaymentMethodRaw } from '@/utils/topupPaymentMethod'

/** Issue / upgrade membership from Check Balance (cash default; USDC requires QR payment first). */
export function ReadBalanceMembershipSection({
	mode,
	tiers,
	currencyPrefix,
	disabled,
	onPurchaseTier,
}: {
	mode: 'join' | 'upgrade'
	tiers: ReadBalanceMembershipTierChoice[]
	currencyPrefix: string
	disabled?: boolean
	onPurchaseTier: (tier: ReadBalanceMembershipTierChoice, method: TopupPaymentMethodRaw) => void
}) {
	const [paymentMethod, setPaymentMethod] = useState<TopupPaymentMethodRaw>('cash')

	if (tiers.length === 0) return null

	const title = mode === 'upgrade' ? 'Upgrade membership' : 'Issue membership'
	const hint =
		mode === 'upgrade'
			? 'Select a tier and payment method. The member on this balance screen will receive the new card.'
			: 'Select a tier and payment method to issue a membership card for this customer.'

	return (
		<section className="rounded-2xl bg-white p-4 shadow-sm">
			<p className="text-xs font-semibold uppercase tracking-wide text-slate-500">{title}</p>
			<p className="mt-1 text-sm text-slate-600">{hint}</p>
			<div className="mt-3 flex gap-2">
				<button
					type="button"
					disabled={disabled}
					onClick={() => setPaymentMethod('cash')}
					className={`flex-1 rounded-xl border px-3 py-2 text-sm font-semibold transition ${
						paymentMethod === 'cash'
							? 'border-[#7C3AED] bg-[#7C3AED]/10 text-[#7C3AED]'
							: 'border-slate-200 bg-slate-50 text-slate-600'
					}`}
				>
					Cash
				</button>
				<button
					type="button"
					disabled={disabled}
					onClick={() => setPaymentMethod('usdc')}
					className={`flex-1 rounded-xl border px-3 py-2 text-sm font-semibold transition ${
						paymentMethod === 'usdc'
							? 'border-[#7C3AED] bg-[#7C3AED]/10 text-[#7C3AED]'
							: 'border-slate-200 bg-slate-50 text-slate-600'
					}`}
				>
					USDC
				</button>
			</div>
			<div className="mt-3 flex flex-col gap-2">
				{tiers.map((t) => {
					const feeLabel = membershipFeeE6ToHuman(t.feeFiat6) || '0'
					const dur = membershipDurationLabel(t.durationKind)
					return (
						<button
							key={t.tierIndex}
							type="button"
							disabled={disabled}
							onClick={() => onPurchaseTier(t, paymentMethod)}
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
