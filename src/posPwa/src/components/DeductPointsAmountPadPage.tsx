import { useState } from 'react'
import { BeamioAmountPad, formatAmountPadDisplay } from '@/components/BeamioAmountPad'
import { BeamioCompactAmountPadShell } from '@/components/BeamioCompactAmountPadShell'
import {
	isDeductKeypadWithinBalance,
	parseDeductKeypadAmount6,
} from '@/utils/deductPointsExecute'
import { readBalanceFormatUsdcThousands } from '@/utils/readBalanceDisplay'

const DEDUCT_ORANGE = '#ea580c'

function formatAvailablePtsLabel(maxPoints6: bigint): string {
	return `${readBalanceFormatUsdcThousands(Number(maxPoints6) / 1_000_000)} pts`
}

/** iOS `DeductPointsAmountPadFullPage` / `BoxWithConstraintsLikeChargeAmountPad`. */
export function DeductPointsAmountPadPage({
	onCancel,
	onContinue,
	/** When set (e.g. Check Balance), show balance and cap keypad to this amount. */
	maxPoints6,
}: {
	onCancel: () => void
	onContinue: (keypadAmount: string) => void
	maxPoints6?: bigint
}) {
	const [amount, setAmount] = useState('0')
	const parsed = Number(amount.replace(/,/g, ''))
	const hasPositiveAmount = Number.isFinite(parsed) && parsed > 0
	const withinBalance =
		maxPoints6 == null || isDeductKeypadWithinBalance(amount, maxPoints6)
	const canContinue = hasPositiveAmount && withinBalance
	const exceedsBalance =
		maxPoints6 != null && hasPositiveAmount && !withinBalance
	const balanceKnown = maxPoints6 != null

	return (
		<BeamioCompactAmountPadShell
			accent={DEDUCT_ORANGE}
			title="Deduct Points"
			continueTitle="Continue"
			amountDisplay={formatAmountPadDisplay(amount)}
			aboveAmountDisplay={
				balanceKnown ? (
					<p className="text-sm font-medium text-slate-500">
						Available balance:{' '}
						<span className="font-semibold tabular-nums" style={{ color: DEDUCT_ORANGE }}>
							{formatAvailablePtsLabel(maxPoints6)}
						</span>
					</p>
				) : undefined
			}
			belowAmountHint={
				exceedsBalance ? 'Amount exceeds available balance.' : undefined
			}
			canContinue={canContinue}
			onCancel={onCancel}
			onContinue={() => {
				if (maxPoints6 != null && !isDeductKeypadWithinBalance(amount, maxPoints6)) {
					return
				}
				if (!parseDeductKeypadAmount6(amount)) return
				onContinue(amount)
			}}
			keypad={<BeamioAmountPad amount={amount} onAmountChange={setAmount} />}
		/>
	)
}
