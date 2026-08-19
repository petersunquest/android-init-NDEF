import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { membershipDurationLabel, membershipFeeE6ToHuman } from '@/utils/beamioPaymentRouting'
import {
	membershipPurchaseApiAmountHuman,
	membershipPurchaseBalanceCreditHuman,
	type ReadBalanceMembershipTierChoice,
} from '@/utils/readBalanceMembership'

const ACCENT = '#7C3AED'

/** After membership re-scan: confirm fee amount before NFC top-up. */
export function ReadBalanceMembershipConfirmPage({
	tier,
	currencyPrefix,
	mode,
	busy,
	onCancel,
	onConfirm,
}: {
	tier: ReadBalanceMembershipTierChoice
	currencyPrefix: string
	mode: 'join' | 'upgrade'
	busy?: boolean
	onCancel: () => void
	onConfirm: () => void
}) {
	const feeHuman = membershipFeeE6ToHuman(tier.feeFiat6) || '0'
	const chargeHuman = membershipPurchaseApiAmountHuman(tier.feeFiat6, tier.minUsdc6)
	const creditHuman = membershipPurchaseBalanceCreditHuman(tier.feeFiat6, tier.minUsdc6)
	const dur = membershipDurationLabel(tier.durationKind)
	const actionLabel = mode === 'upgrade' ? 'Confirm upgrade' : 'Confirm & issue card'

	return (
		<PosScreenShell bg="bg-[#F9F9FE]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onCancel}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="px-5 pb-[max(1rem,env(safe-area-inset-bottom))] pt-14">
					<div className="flex min-h-0 flex-1 flex-col gap-4">
						<div>
							<p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
								{mode === 'upgrade' ? 'Upgrade membership' : 'Join membership'}
							</p>
							<h1 className="mt-1 text-xl font-bold text-slate-900">{tier.name}</h1>
							{dur ? <p className="mt-1 text-sm text-slate-500">{dur}</p> : null}
						</div>

						<div className="rounded-2xl bg-white p-4 shadow-sm">
							<p className="text-center text-sm font-medium text-slate-500">Amount to charge</p>
							<p
								className="mt-2 text-center text-4xl font-black tabular-nums"
								style={{ color: ACCENT }}
							>
								{currencyPrefix}
								{chargeHuman}
							</p>
							<div className="mt-4 space-y-2 border-t border-slate-100 pt-3 text-sm">
								<div className="flex justify-between gap-2 text-slate-600">
									<span>Membership fee</span>
									<span className="font-semibold tabular-nums text-slate-900">
										{currencyPrefix}
										{feeHuman}
									</span>
								</div>
								<div className="flex justify-between gap-2 text-slate-600">
									<span>Balance credit</span>
									<span className="font-semibold tabular-nums text-slate-900">
										{currencyPrefix}
										{creditHuman}
									</span>
								</div>
							</div>
						</div>

						<p className="text-sm text-slate-600">
							Collect this amount from the member, then confirm to mint or renew the
							membership card on-chain.
						</p>

						<button
							type="button"
							disabled={busy}
							aria-busy={busy}
							onClick={onConfirm}
							className="mt-auto rounded-xl py-4 text-lg font-semibold text-white disabled:opacity-45"
							style={{ backgroundColor: ACCENT }}
						>
							{actionLabel}
						</button>
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
