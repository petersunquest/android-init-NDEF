import { CaddBaseCompositeIcon, UsdcBaseCompositeIcon } from '@/components/ChainTokenCompositeIcon'
import type { UIDAssetsResult } from '@/types/pos'
import {
	readBalanceFormatMoney,
	readBalanceFormatUsdcThousands,
	readBalanceLastTopUpFallbackLine,
} from '@/utils/readBalanceDisplay'

const OUTLINE = '#737685'
const ON_SURFACE = '#1A1C1F'

export interface ReadBalanceStatsCardProps {
	assets: UIDAssetsResult
	cardCurrency: string
	usdcBalance: number
	caddBalance: number | null
	caddLoading?: boolean
}

export function ReadBalanceStatsCard({
	assets,
	cardCurrency,
	usdcBalance,
	caddBalance,
	caddLoading = false,
}: ReadBalanceStatsCardProps) {
	const usdcParts = readBalanceFormatMoney(usdcBalance, 'USDC')
	const p6Trim = assets.posLastTopupPointsE6?.trim() ?? ''
	const p6 = Number(p6Trim)
	const hasTopUp = Number.isFinite(p6) && p6 > 0

	return (
		<div className="rounded-3xl bg-[#F3F3F8] p-6">
			<div className="flex items-start gap-4">
				<div className="min-w-0 flex-1">
					<p
						className="text-[11px] font-medium tracking-widest"
						style={{ color: OUTLINE }}
					>
						LAST TOP-UP
					</p>
					{hasTopUp ? (
						<div className="mt-1 flex items-end gap-0.5">
							{(() => {
								const row = readBalanceFormatMoney(p6 / 1_000_000, cardCurrency)
								return (
									<>
										{row.prefix ? (
											<span className="text-xs font-bold" style={{ color: ON_SURFACE }}>
												{row.prefix}
											</span>
										) : null}
										<span
											className="font-mono text-xl font-bold"
											style={{ color: ON_SURFACE }}
										>
											{row.mid}
										</span>
										{row.suffix ? (
											<span className="text-xs font-medium" style={{ color: OUTLINE }}>
												{row.suffix.trim()}
											</span>
										) : null}
									</>
								)
							})()}
						</div>
					) : (
						<p className="mt-1 font-mono text-xl font-bold" style={{ color: ON_SURFACE }}>
							{readBalanceLastTopUpFallbackLine(assets)}
						</p>
					)}
				</div>
				<div className="min-w-0 flex-1 text-right">
					<div className="flex items-baseline justify-end gap-1">
						<UsdcBaseCompositeIcon size={18} badgeSize={11} />
						<span className="font-mono text-xl font-bold" style={{ color: ON_SURFACE }}>
							{readBalanceFormatUsdcThousands(usdcBalance)}
						</span>
						<span className="text-xs font-medium" style={{ color: OUTLINE }}>
							{usdcParts.suffix.trim()}
						</span>
					</div>
					<div className="mt-3 flex items-baseline justify-end gap-1">
						<CaddBaseCompositeIcon size={18} badgeSize={11} />
						{caddLoading ? (
							<span className="text-sm font-semibold" style={{ color: OUTLINE }}>
								Loading...
							</span>
						) : caddBalance != null ? (
							<>
								<span className="font-mono text-xl font-bold" style={{ color: ON_SURFACE }}>
									{readBalanceFormatUsdcThousands(caddBalance)}
								</span>
								<span className="text-xs font-medium" style={{ color: OUTLINE }}>
									CADD
								</span>
							</>
						) : (
							<span className="font-mono text-xl font-semibold" style={{ color: OUTLINE }}>
								—
							</span>
						)}
					</div>
				</div>
			</div>
		</div>
	)
}
