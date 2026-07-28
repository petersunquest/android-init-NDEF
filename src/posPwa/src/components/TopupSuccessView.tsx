import { CheckCircle2, Printer, Share2 } from 'lucide-react'
import { printPosReceipt } from '@/bridge/cashTreesPrintBridge'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosReceiptMetadataCard } from '@/components/PosReceiptMetadataCard'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { ReadBalancePassHeroCard } from '@/components/ReadBalancePassHeroCard'
import { buildFallbackPassHero, type PosSuccessPassHeroProps } from '@/utils/posSuccessHero'
import { readBalanceFormatMoney } from '@/utils/readBalanceDisplay'
import {
	formatPosReceiptDate,
	shortWalletAddr,
} from '@/utils/posReceiptUtils'
import { buildTopupReceiptPlainText } from '@/utils/posReceiptPlainText'
import type { TopupExecuteSuccess } from '@/utils/topupExecute'

const PAGE_BG = '#f5f5f7'
const CHECK_GREEN = '#34c759'
const ON_SURFACE = 'rgba(0,0,0,0.84)'

/** iOS `TopupSuccessView` — amount header, pass hero, receipt card, print. */
export function TopupSuccessView({
	result,
	passHero: passHeroProp,
	pointSystemEnabled: _pointSystemEnabled,
	onDone,
}: {
	result: TopupExecuteSuccess
	passHero?: PosSuccessPassHeroProps
	pointSystemEnabled?: boolean
	onDone: () => void
}) {
	const passHero =
		passHeroProp ??
		result.passHero ??
		buildFallbackPassHero({
			currency: result.cardCurrency ?? 'CAD',
			balanceAmount:
				result.postBalance !== '—' && Number.isFinite(Number(result.postBalance))
					? Number(result.postBalance)
					: undefined,
			memberNo: result.memberNo,
			customerBeamioTag: result.customerBeamioTag,
			customerWalletAddress: result.address,
		})
	const currency = result.cardCurrency ?? 'CAD'
	const amountNum = Number(result.amount)
	const amtParts = readBalanceFormatMoney(
		Number.isFinite(amountNum) ? amountNum : 0,
		currency,
	)
	const memRaw = result.memberNo?.trim() ?? ''
	const displayMemberNo =
		memRaw || shortWalletAddr(result.address) || passHero.memberNo || '—'
	const dateStr = formatPosReceiptDate()

	const onPrint = () => {
		const text = buildTopupReceiptPlainText({
			amount: result.amount,
			postBalance: result.postBalance,
			cardCurrency: currency,
			dateStr,
			memberNo: displayMemberNo,
			address: result.address,
			txHash: result.txHash,
			settlementViaQr: result.settlementViaQr,
		})
		if (!printPosReceipt({ text, title: 'Top-Up Receipt' })) {
			window.print()
		}
	}

	const onShare = async () => {
		const text = [
			'Top-Up Approved',
			`+${amtParts.prefix}${amtParts.mid}${amtParts.suffix}`,
			`Date: ${dateStr}`,
			result.txHash ? `Tx: ${result.txHash}` : '',
		]
			.filter(Boolean)
			.join('\n')
		if (navigator.share) {
			try {
				await navigator.share({ title: 'Top-Up Receipt', text })
				return
			} catch {
				/* cancelled */
			}
		}
		void navigator.clipboard?.writeText(text)
	}

	return (
		<PosScreenShell bg="bg-[#f5f5f7]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onDone}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="overflow-y-auto px-0 pb-0 pt-14">
					<div className="flex flex-col">
						<div className="flex flex-col items-center px-5 pb-3 pt-10">
							<div className="flex h-14 w-14 items-center justify-center rounded-full bg-white shadow-sm">
								<CheckCircle2 className="h-8 w-8" style={{ color: CHECK_GREEN }} aria-hidden />
							</div>
							<div className="mt-1 flex items-baseline gap-0.5">
								<span className="text-base font-medium text-[#86868b]">+</span>
								{amtParts.prefix ? (
									<span className="text-[10px] font-bold" style={{ color: ON_SURFACE }}>
										{amtParts.prefix}
									</span>
								) : null}
								<span
									className="text-4xl font-light tabular-nums"
									style={{ color: ON_SURFACE }}
								>
									{amtParts.mid}
								</span>
								{amtParts.suffix ? (
									<span className="text-[10px] font-bold" style={{ color: ON_SURFACE }}>
										{amtParts.suffix}
									</span>
								) : null}
							</div>
						</div>

						<div className="space-y-3 px-5 pb-24">
							<ReadBalancePassHeroCard
								memberDisplayName={passHero.memberDisplayName}
								memberNo={passHero.memberNo}
								tierDisplayName={passHero.tierDisplayName}
								tierDiscountPercent={passHero.tierDiscountPercent}
								programCardDisplayName={passHero.programCardDisplayName}
								tierCardBackgroundHex={passHero.tierCardBackgroundHex}
								cardMetadataImageUrl={passHero.cardMetadataImageUrl}
								balanceParts={passHero.balanceParts}
								balanceSubtitle={passHero.balanceSubtitle}
							/>
							<PosReceiptMetadataCard
								variant="topup"
								memberNo={displayMemberNo}
								txHash={result.txHash}
								settlementViaQr={result.settlementViaQr}
								dateStr={dateStr}
							/>
						</div>
					</div>
				</PosScreenMain>

				<div
					className="shrink-0 border-t border-black/5 px-5 pb-[max(0.5rem,env(safe-area-inset-bottom))] pt-3"
					style={{ backgroundColor: PAGE_BG }}
				>
					<div className="mb-2 flex justify-end gap-1">
						<button
							type="button"
							onClick={() => void onShare()}
							className="flex h-11 w-11 items-center justify-center rounded-full text-slate-600"
							aria-label="Share receipt"
						>
							<Share2 className="h-5 w-5" />
						</button>
					</div>
					<button
						type="button"
						onClick={onPrint}
						className="flex w-full items-center justify-center gap-2 rounded-xl border border-black/30 py-3.5 text-sm font-semibold text-slate-800"
					>
						<Printer className="h-4 w-4" aria-hidden />
						Print Receipt
					</button>
				</div>
			</div>
		</PosScreenShell>
	)
}
