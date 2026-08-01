import type { ReactNode } from 'react'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'

const TOPUP_BLUE = '#1562f0'
const BONUS_PINK = '#ec4899'
const DEDUCT_ORANGE = '#ea580c'

function formatUsdAmount(n: number): string {
	if (!Number.isFinite(n) || n <= 0) return '0.00'
	return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

/** Scan flow post-read executing layout — iOS `ScanSheet` grouped background + optional bottom amount. */
export function PosScanExecutingShell({
	title,
	center,
	bottomAmount,
	bottomBonus,
	bottomTone = 'topup',
}: {
	title: string
	center: ReactNode
	bottomAmount?: number
	bottomBonus?: number
	bottomTone?: 'topup' | 'charge' | 'deduct'
}) {
	const showBottom = bottomAmount != null && bottomAmount > 0
	const labelColor =
		bottomTone === 'topup'
			? TOPUP_BLUE
			: bottomTone === 'deduct'
				? DEDUCT_ORANGE
				: '#86868b'
	const valueColor =
		bottomTone === 'topup'
			? TOPUP_BLUE
			: bottomTone === 'deduct'
				? DEDUCT_ORANGE
				: '#000000'
	const bottomLabel =
		bottomTone === 'charge'
			? 'Total Amount'
			: bottomTone === 'deduct'
				? 'Points to Deduct'
				: 'Top-Up Amount'

	return (
		<PosScreenShell bg="bg-[#f2f2f7]">
			<PosScreenMain className="px-0">
				<div className="flex min-h-0 flex-1 flex-col">
					<div className="shrink-0 px-2 pb-2.5 pt-[max(0.375rem,env(safe-area-inset-top))]">
						<p className="text-center text-[17px] font-semibold text-[#1a1c1f]">{title}</p>
					</div>
					<div className="flex min-h-0 flex-1 flex-col items-center px-4">
						<div className="flex w-full flex-1 items-center justify-center">{center}</div>
						{showBottom ? (
							<div className="w-full shrink-0 pb-6 pt-2 text-center">
								<p className="text-[13px] font-medium" style={{ color: labelColor }}>
									{bottomLabel}
								</p>
								<p
									className="text-[52px] font-semibold leading-none"
									style={{ color: valueColor }}
								>
									{bottomTone === 'deduct'
										? `${formatUsdAmount(bottomAmount!)} pt`
										: `$${formatUsdAmount(bottomAmount!)}`}
								</p>
								{bottomBonus != null && bottomBonus > 1e-6 ? (
									<p className="mt-1 text-[15px] font-semibold" style={{ color: BONUS_PINK }}>
										Bonus ${formatUsdAmount(bottomBonus)}
									</p>
								) : null}
							</div>
						) : (
							<div className="shrink-0 pb-[max(1rem,env(safe-area-inset-bottom))]" />
						)}
					</div>
				</div>
			</PosScreenMain>
		</PosScreenShell>
	)
}
