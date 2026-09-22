import { useMemo, useState } from 'react'
import { WalletCards } from 'lucide-react'
import { BeamioAmountPad, formatAmountPadDisplay } from '@/components/BeamioAmountPad'
import { BeamioCompactAmountPadShell } from '@/components/BeamioCompactAmountPadShell'
import { UsdcBaseCompositeIcon } from '@/components/ChainTokenCompositeIcon'
import {
	deductChargeRewardPoints6,
	isDeductKeypadWithinBalance,
	parseDeductKeypadAmount6,
} from '@/utils/deductPointsExecute'
import { readBalanceFormatUsdcThousands } from '@/utils/readBalanceDisplay'
import { displayFiatPrefixFromCode } from '@/utils/display'
import type { UIDAssetsResult } from '@/types/pos'

const DEDUCT_ORANGE = '#ea580c'
const USDC_BLUE = '#2563eb'

export type PointsPaymentMode = 'burn-pt' | 'usdc-topup'

const MODE_LABEL: Record<PointsPaymentMode, string> = {
	'burn-pt': 'Reward PT',
	'usdc-topup': 'Top Up',
}

function formatAvailablePtsLabel(maxPoints6: bigint): string {
	return `${readBalanceFormatUsdcThousands(Number(maxPoints6) / 1_000_000)} PT`
}

/** iOS `DeductPointsAmountPadFullPage` / `BoxWithConstraintsLikeChargeAmountPad`. */
export function DeductPointsAmountPadPage({
	onCancel,
	onContinue,
	assets,
	merchantInfraCard,
	allowUsdcTopup = true,
	convertibleTopupAmount,
	maxPoints6,
}: {
	onCancel: () => void
	onContinue: (input: { mode: PointsPaymentMode; keypadAmount: string }) => void
	assets?: UIDAssetsResult | null
	merchantInfraCard?: string | null
		allowUsdcTopup?: boolean
		/** Maximum amount payable with cross-store convertible PT, in merchant currency. */
		convertibleTopupAmount?: number | null
	maxPoints6?: bigint
}) {
	const [amount, setAmount] = useState('0')
	const [mode, setMode] = useState<PointsPaymentMode>('burn-pt')
	const parsed = Number(amount.replace(/,/g, ''))
	const hasPositiveAmount = Number.isFinite(parsed) && parsed > 0
	const infra = merchantInfraCard?.trim().toLowerCase() ?? ''
	const merchantCard = infra
		? assets?.cards?.find((card) => card.cardAddress.trim().toLowerCase() === infra)
		: undefined
	/*
	 * Burnable Reward PT is only the Workspaces current merchant card.
	 * Wallet assets copy another store's #13 onto the top-level field (cards[0]).
	 */
	const points6 =
		assets && infra ? deductChargeRewardPoints6(assets, infra) : 0n
	const usdcBalance = convertibleTopupAmount ?? 0
	const merchantCurrency = (
		merchantCard?.cardCurrency?.trim() ||
		(assets?.cards && assets.cards.length > 0 ? '' : assets?.cardCurrency) ||
		'CAD'
	).toUpperCase()
	const merchantCurrencyPrefix = displayFiatPrefixFromCode(merchantCurrency)
	const effectiveMaxPoints6 = maxPoints6 ?? points6
	const withinPoints =
		effectiveMaxPoints6 == null || isDeductKeypadWithinBalance(amount, effectiveMaxPoints6)
	const withinUsdc = Number.isFinite(usdcBalance) && parsed <= usdcBalance
	const withinBalance = mode === 'burn-pt' ? withinPoints : withinUsdc
	const canContinue = hasPositiveAmount && withinBalance
	const exceedsBalance = hasPositiveAmount && !withinBalance
	const balanceKnown = maxPoints6 != null || assets != null
	const nextMode = useMemo<PointsPaymentMode>(
		() => (mode === 'burn-pt' && allowUsdcTopup ? 'usdc-topup' : 'burn-pt'),
		[allowUsdcTopup, mode],
	)
	const modeAccent = mode === 'burn-pt' ? DEDUCT_ORANGE : USDC_BLUE

	return (
		<BeamioCompactAmountPadShell
			accent={DEDUCT_ORANGE}
			title="Points"
			continueTitle="Continue"
			amountDisplay={formatAmountPadDisplay(amount)}
			amountTrailing={
				<button
					type="button"
					disabled={!allowUsdcTopup}
					aria-pressed={mode === 'usdc-topup'}
					onClick={() => {
						if (!allowUsdcTopup) return
						setMode(nextMode)
					}}
					className="flex shrink-0 flex-col items-center gap-2 disabled:opacity-45"
					aria-label={`Payment method ${MODE_LABEL[mode]}. Tap to switch`}
				>
					<span className="text-xs font-semibold" style={{ color: modeAccent }}>
						{MODE_LABEL[mode]}
					</span>
					<span
						className="flex h-11 w-11 items-center justify-center rounded-full"
						style={{ backgroundColor: `${modeAccent}24` }}
					>
						{mode === 'usdc-topup' ? (
							<UsdcBaseCompositeIcon size={22} />
						) : (
							<WalletCards
								className="h-5 w-5"
								style={{ color: modeAccent }}
								aria-hidden
							/>
						)}
					</span>
				</button>
			}
			aboveAmountDisplay={
				balanceKnown ? (
					<div className="space-y-2">
						<div className="text-center">
							{mode === 'burn-pt' ? (
								<p
									className="truncate text-2xl font-black leading-tight tabular-nums sm:text-3xl"
									style={{ color: DEDUCT_ORANGE }}
								>
									{formatAvailablePtsLabel(effectiveMaxPoints6)}
								</p>
							) : (
								<p
									className="truncate text-2xl font-black leading-tight tabular-nums sm:text-3xl"
									style={{ color: USDC_BLUE }}
								>
									{merchantCurrencyPrefix}{readBalanceFormatUsdcThousands(usdcBalance)}
								</p>
							)}
						</div>
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
