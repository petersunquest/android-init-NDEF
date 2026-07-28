import { Loader2 } from 'lucide-react'

const TOPUP_BLUE = '#1562f0'
const LABEL_GRAY = '#86868b'
const BONUS_PINK = '#ec4899'

function formatUsdAmount(n: number): string {
	if (!Number.isFinite(n) || n <= 0) return '0.00'
	return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

/** iOS `topupScanCenterContent` NFC/QR post-scan loading card. */
export function PosTopupExecutingCard({
	signingInProgress = false,
	customerHint,
	totalCredit,
	bonusCredit,
}: {
	signingInProgress?: boolean
	customerHint?: string
	totalCredit?: number
	bonusCredit?: number
}) {
	const showTotals = (totalCredit ?? 0) > 0
	const heightClass = showTotals ? 'h-[330px]' : 'h-[280px]'

	return (
		<div
			className={`relative w-full max-w-[360px] overflow-hidden rounded-[2rem] border-2 border-black/10 bg-white ${heightClass}`}
		>
			<div className="flex h-full flex-col items-center justify-center px-6 py-6 text-center">
				<Loader2
					className="mb-4 h-8 w-8 animate-spin"
					style={{ color: TOPUP_BLUE }}
					aria-hidden
				/>
				{showTotals && totalCredit != null ? (
					<div className="mb-3 space-y-1">
						<p className="text-xs font-medium" style={{ color: LABEL_GRAY }}>
							Total credit
						</p>
						<p
							className="text-[30px] font-semibold leading-none"
							style={{ color: TOPUP_BLUE }}
						>
							${formatUsdAmount(totalCredit)}
						</p>
						{bonusCredit != null && bonusCredit > 1e-6 ? (
							<p className="text-[15px] font-semibold" style={{ color: BONUS_PINK }}>
								Bonus ${formatUsdAmount(bonusCredit)}
							</p>
						) : null}
					</div>
				) : null}
				<div className="space-y-1">
					<p className="text-lg font-semibold text-[#1a1c1f]">
						{signingInProgress ? 'Sign & execute' : 'Loading...'}
					</p>
					{signingInProgress && customerHint ? (
						<p className="text-[11px] text-[#86868b]">{customerHint}</p>
					) : null}
					<p className="text-xs text-[#86868b]">Completing top-up…</p>
				</div>
			</div>
		</div>
	)
}
