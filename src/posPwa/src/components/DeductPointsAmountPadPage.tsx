import { useState } from 'react'
import { CreditCard, WalletCards } from 'lucide-react'
import { BeamioAmountPad, formatAmountPadDisplay } from '@/components/BeamioAmountPad'
import { BeamioCompactAmountPadShell } from '@/components/BeamioCompactAmountPadShell'
import {
	isDeductKeypadWithinBalance,
	parseDeductKeypadAmount6,
} from '@/utils/deductPointsExecute'
import { readBalanceFormatUsdcThousands } from '@/utils/readBalanceDisplay'
import type { UIDAssetsResult } from '@/types/pos'

const DEDUCT_ORANGE = '#ea580c'
const USDC_BLUE = '#2563eb'

function formatAvailablePtsLabel(maxPoints6: bigint): string {
	return `${readBalanceFormatUsdcThousands(Number(maxPoints6) / 1_000_000)} pts`
}

export type PointsPaymentMode = 'burn-pt' | 'usdc-topup'

/** iOS `DeductPointsAmountPadFullPage` / `BoxWithConstraintsLikeChargeAmountPad`. */
export function DeductPointsAmountPadPage({
	onCancel,
	onContinue,
	assets,
	allowUsdcTopup = true,
	convertibleTopupAmount,
	maxPoints6,
}: {
	onCancel: () => void
	onContinue: (input: { mode: PointsPaymentMode; keypadAmount: string }) => void
	assets?: UIDAssetsResult | null
		allowUsdcTopup?: boolean
		/** Maximum amount payable with cross-store convertible PT, in merchant currency. */
		convertibleTopupAmount?: number | null
	maxPoints6?: bigint
}) {
	const [amount, setAmount] = useState('0')
	const [mode, setMode] = useState<PointsPaymentMode>('burn-pt')
	const parsed = Number(amount.replace(/,/g, ''))
	const hasPositiveAmount = Number.isFinite(parsed) && parsed > 0
	const points6 = (() => {
		try {
			return BigInt(String(assets?.chargeRewardPoints6 ?? assets?.points6 ?? '0'))
		} catch {
			return 0n
		}
	})()
	const usdcBalance = convertibleTopupAmount ?? 0
	const effectiveMaxPoints6 = maxPoints6 ?? points6
	const withinPoints =
		effectiveMaxPoints6 == null || isDeductKeypadWithinBalance(amount, effectiveMaxPoints6)
	const withinUsdc = Number.isFinite(usdcBalance) && parsed <= usdcBalance
	const withinBalance = mode === 'burn-pt' ? withinPoints : withinUsdc
	const canContinue = hasPositiveAmount && withinBalance
	const exceedsBalance = hasPositiveAmount && !withinBalance
	const balanceKnown = maxPoints6 != null || assets != null

	return (
		<BeamioCompactAmountPadShell
			accent={DEDUCT_ORANGE}
			title="Points"
			continueTitle="Continue"
			amountDisplay={formatAmountPadDisplay(amount)}
			amountTrailing={
				<div className="flex flex-col gap-1">
					{allowUsdcTopup ? <button
						type="button"
						aria-pressed={mode === 'burn-pt'}
						onClick={() => setMode('burn-pt')}
						className={`flex h-10 w-10 items-center justify-center rounded-xl border ${
							mode === 'burn-pt'
								? 'border-orange-500 bg-orange-50 text-orange-600'
								: 'border-slate-200 bg-white text-slate-400'
						}`}
						aria-label="Burn merchant Reward PT"
					>
						<WalletCards className="h-5 w-5" aria-hidden />
					</button> : null}
					<button
						type="button"
						aria-pressed={mode === 'usdc-topup'}
						onClick={() => setMode('usdc-topup')}
						className={`flex h-10 w-10 items-center justify-center rounded-xl border ${
							mode === 'usdc-topup'
								? 'border-blue-500 bg-blue-50 text-blue-600'
								: 'border-slate-200 bg-white text-slate-400'
						}`}
						aria-label="Use convertible USDC for merchant store credit"
					>
						<CreditCard className="h-5 w-5" aria-hidden />
					</button>
				</div>
			}
			aboveAmountDisplay={
				balanceKnown ? (
					<div className="space-y-1 text-sm font-medium text-slate-500">
						<p>Merchant Reward PT: <span className="font-semibold" style={{ color: DEDUCT_ORANGE }}>{formatAvailablePtsLabel(effectiveMaxPoints6)}</span></p>
						<p>PT convertible for top-up: <span className="font-semibold" style={{ color: USDC_BLUE }}>{readBalanceFormatUsdcThousands(usdcBalance)}</span></p>
						<p className="text-xs text-slate-400">{mode === 'burn-pt' ? 'Burn merchant Reward PT' : 'Use USDC to top up merchant store credit'}</p>
					</div>
				) : undefined
			}
			belowAmountHint={
				exceedsBalance
					? mode === 'burn-pt'
						? 'Amount exceeds available merchant Reward PT.'
						: 'Amount exceeds convertible USDC.'
					: undefined
			}
			canContinue={canContinue}
			onCancel={onCancel}
			onContinue={() => {
				if (!withinBalance) {
					return
				}
				if (!parseDeductKeypadAmount6(amount)) return
				onContinue({ mode, keypadAmount: amount })
			}}
			keypad={<BeamioAmountPad amount={amount} onAmountChange={setAmount} />}
		/>
	)
}
