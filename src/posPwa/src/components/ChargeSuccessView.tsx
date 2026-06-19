import { AlertTriangle, Printer, Share2 } from 'lucide-react'
import { printPosReceipt } from '@/bridge/cashTreesPrintBridge'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosPaymentApprovedPassHero } from '@/components/PosPaymentApprovedPassHero'
import { PosPaymentRoutingCard } from '@/components/PosPaymentRoutingCard'
import { PosReceiptMetadataCard } from '@/components/PosReceiptMetadataCard'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { buildFallbackPassHero, type PosSuccessPassHeroProps } from '@/utils/posSuccessHero'
import { readBalanceFormatMoney } from '@/utils/readBalanceDisplay'
import { formatPosReceiptDate, shortWalletAddr } from '@/utils/posReceiptUtils'
import { buildChargeReceiptPlainText } from '@/utils/posReceiptPlainText'
import type { ChargeExecuteSuccess } from '@/utils/chargeExecute'

function ReceiptRadialBackdrop() {
	return (
		<div className="pointer-events-none absolute inset-0 overflow-hidden" aria-hidden>
			<div
				className="absolute -right-24 -top-64 h-[280px] w-[280px] rounded-full blur-[60px]"
				style={{ backgroundColor: 'rgba(219,225,255,0.35)' }}
			/>
			<div
				className="absolute -left-36 top-80 h-[260px] w-[260px] rounded-full blur-[50px]"
				style={{ backgroundColor: 'rgba(179,197,255,0.28)' }}
			/>
		</div>
	)
}

/** iOS `PaymentSuccessView` — Approved pass hero, Smart Routing, receipt metadata. */
export function ChargeSuccessView({
	result,
	passHero: passHeroProp,
	onDone,
}: {
	result: ChargeExecuteSuccess
	passHero?: PosSuccessPassHeroProps
	onDone: () => void
}) {
	const currency = result.cardCurrency ?? 'CAD'
	const amountNum = Number(result.amount)
	const subtotalNum = Number(result.subtotal ?? result.amount)
	const tipNum = Number(result.tip ?? '0') || 0
	const taxP = result.chargeTaxPercent ?? 0
	const discP = result.chargeTierDiscountPercent ?? 0
	const hasResolvedPassHero = Boolean(passHeroProp ?? result.passHero)
	const passHero =
		passHeroProp ??
		result.passHero ??
		buildFallbackPassHero({
			currency,
			balanceAmount:
				result.postBalance !== '—' && Number.isFinite(Number(result.postBalance))
					? Number(result.postBalance)
					: undefined,
			memberNo: result.memberNo,
			customerBeamioTag: result.customerBeamioTag,
			customerWalletAddress: result.customerWalletAddress,
			cardName: result.cardName,
			tierName: result.tierName,
			tierDiscountPercent: discP,
		})
	const memRaw = result.memberNo?.trim() ?? ''
	const displayMemberNo =
		memRaw ||
		shortWalletAddr(result.customerWalletAddress) ||
		shortWalletAddr(result.payee) ||
		passHero.memberNo ||
		'—'
	const dateStr = formatPosReceiptDate()

	const postNum = Number(result.postBalance)
	const heroBalance =
		hasResolvedPassHero
			? passHero.balanceParts
			: Number.isFinite(postNum) && result.postBalance !== '—'
			? readBalanceFormatMoney(postNum, currency)
			: passHero.balanceParts

	const onPrint = () => {
		const text = buildChargeReceiptPlainText({
			amount: result.amount,
			postBalance: result.postBalance,
			cardCurrency: currency,
			subtotal: result.subtotal,
			tip: result.tip,
			dateStr,
			memberNo: displayMemberNo,
			payee: result.payee,
			customerWalletAddress: result.customerWalletAddress,
			txHash: result.txHash,
			settlementViaQr: result.settlementViaQr,
		})
		if (!printPosReceipt({ text, title: 'Payment Receipt' })) {
			window.print()
		}
	}

	const onShare = async () => {
		const text = [
			'Payment Approved',
			`${amountNum.toFixed(2)} ${currency}`,
			`Subtotal: ${subtotalNum.toFixed(2)}`,
			result.tip ? `Tip: ${result.tip}` : '',
			result.txHash ? `Tx: ${result.txHash}` : '',
			`Date: ${dateStr}`,
		]
			.filter(Boolean)
			.join('\n')
		if (navigator.share) {
			try {
				await navigator.share({ title: 'Payment Receipt', text })
				return
			} catch {
				/* cancelled */
			}
		}
		void navigator.clipboard?.writeText(text)
	}

	return (
		<PosScreenShell bg="bg-[#f9f9fe]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onDone}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<div className="absolute right-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10 flex">
					<button
						type="button"
						onClick={() => void onShare()}
						className="flex h-11 w-10 items-center justify-center text-slate-600"
						aria-label="Share receipt"
					>
						<Share2 className="h-[17px] w-[17px]" />
					</button>
					<button
						type="button"
						onClick={onPrint}
						className="flex h-11 w-10 items-center justify-center text-slate-600"
						aria-label="Print receipt"
					>
						<Printer className="h-[17px] w-[17px]" />
					</button>
				</div>

				<PosScreenMain className="relative overflow-y-auto px-0 pb-8 pt-14">
					<ReceiptRadialBackdrop />
					<div className="relative space-y-5 px-6 pb-8 pt-14">
						<PosPaymentApprovedPassHero
							memberDisplayName={passHero.memberDisplayName}
							memberNo={passHero.memberNo}
							tierDisplayName={passHero.tierDisplayName}
							tierDiscountPercent={passHero.tierDiscountPercent}
							programCardDisplayName={passHero.programCardDisplayName}
							tierCardBackgroundHex={passHero.tierCardBackgroundHex}
							cardMetadataImageUrl={passHero.cardMetadataImageUrl}
							balanceParts={heroBalance}
							balanceSubtitle={passHero.balanceSubtitle}
						/>

						{Number.isFinite(subtotalNum) && subtotalNum > 0 ? (
							<PosPaymentRoutingCard
								amountTotal={Number.isFinite(amountNum) ? amountNum : subtotalNum}
								subtotal={subtotalNum}
								tip={tipNum}
								currency={currency}
								taxPercent={taxP}
								tierDiscountPercent={discP}
							/>
						) : null}

						<PosReceiptMetadataCard
							variant="charge"
							memberNo={displayMemberNo}
							txHash={result.txHash}
							settlementViaQr={result.settlementViaQr}
							dateStr={dateStr}
						/>
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}

export function ChargeInsufficientFundsView({
	message,
	requiredLabel,
	availableLabel,
	onDone,
}: {
	message: string
	requiredLabel?: string
	availableLabel?: string
	onDone: () => void
}) {
	return (
		<PosScreenShell bg="bg-[#f9f9fe]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onDone}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="items-center justify-center px-6 pt-14 text-center">
					<div
						className="flex h-14 w-14 items-center justify-center rounded-full"
						style={{ backgroundColor: '#ffdad6' }}
					>
						<AlertTriangle className="h-7 w-7 text-[#93000a]" aria-hidden />
					</div>
					<p className="mt-4 text-[28px] font-black text-[#1a1c1f]">Insufficient Balance</p>
					<p className="mt-2 max-w-sm text-sm text-[#434654]">{message}</p>
					{requiredLabel ? (
						<p className="mt-4 text-sm text-[#1a1c1f]">
							Required: <span className="font-semibold">{requiredLabel}</span>
						</p>
					) : null}
					{availableLabel ? (
						<p className="mt-1 text-sm text-[#1a1c1f]">
							Available: <span className="font-semibold">{availableLabel}</span>
						</p>
					) : null}
					<button
						type="button"
						onClick={onDone}
						className="mt-8 w-full max-w-md rounded-full py-3.5 text-base font-bold text-white"
						style={{
							background: 'linear-gradient(135deg, #004bc3 0%, #0052d2 100%)',
						}}
					>
						Back to Home
					</button>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
