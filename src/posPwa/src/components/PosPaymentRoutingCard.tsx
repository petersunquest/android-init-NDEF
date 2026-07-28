import { Cpu } from 'lucide-react'
import {
	beamioTierDiscountPercentLabel,
	readBalanceFormatMoney,
	type ReadBalanceMoneyParts,
} from '@/utils/readBalanceDisplay'
import { beamioTierDiscountFiatAmount } from '@/utils/posReceiptUtils'

const PRIMARY = '#004b93'
const PRIMARY_CONTAINER = '#004bc3'
const ON_SURFACE = '#1a1c1f'
const ON_SURFACE_VARIANT = '#434654'
const OUTLINE = '#737685'
const SURFACE_LOW = '#f3f3f8'

function MoneyParts({
	parts,
	className,
	size = 'md',
}: {
	parts: ReadBalanceMoneyParts
	className?: string
	size?: 'md' | 'lg'
}) {
	const main = size === 'lg' ? 'text-[30px] sm:text-[34px]' : 'text-sm'
	const side = size === 'lg' ? 'text-xl' : 'text-xs'
	return (
		<span className={`inline-flex items-baseline gap-0.5 font-mono font-bold ${className ?? ''}`}>
			{parts.prefix ? <span className={side}>{parts.prefix}</span> : null}
			<span className={main}>{parts.mid}</span>
			{parts.suffix ? <span className={side}>{parts.suffix}</span> : null}
		</span>
	)
}

function RoutingLine({
	label,
	amount,
	currency,
	negative,
	foreground = ON_SURFACE,
}: {
	label: string
	amount: number
	currency: string
	negative?: boolean
	foreground?: string
}) {
	const parts = readBalanceFormatMoney(amount, currency)
	return (
		<div className="flex items-center justify-between gap-3">
			<span className="text-sm" style={{ color: ON_SURFACE_VARIANT }}>
				{label}
			</span>
			<span className="inline-flex items-baseline gap-0.5" style={{ color: foreground }}>
				{negative ? <span className="text-xs font-semibold">- </span> : null}
				<MoneyParts parts={parts} size="md" />
			</span>
		</div>
	)
}

/** iOS `paymentSuccessReceiptRoutingCard` — total + Smart Routing Engine breakdown. */
export function PosPaymentRoutingCard({
	amountTotal,
	subtotal,
	tip,
	currency,
	taxPercent,
	tierDiscountPercent,
	compact = false,
}: {
	amountTotal: number
	subtotal: number
	tip: number
	currency: string
	taxPercent: number
	tierDiscountPercent: number
	compact?: boolean
}) {
	const taxAmt = subtotal * (taxPercent / 100)
	const discAmt = beamioTierDiscountFiatAmount(subtotal, tierDiscountPercent)
	const totalParts = readBalanceFormatMoney(amountTotal, currency)

	return (
		<div
			className="w-full rounded-2xl p-[18px]"
			style={{ backgroundColor: SURFACE_LOW }}
		>
			<div className="flex justify-center">
				<MoneyParts
					parts={totalParts}
					size={compact ? 'md' : 'lg'}
					className="text-[#004bc3]"
				/>
			</div>
			<div className="my-3 h-px" style={{ backgroundColor: 'rgba(195,198,214,0.35)' }} />
			<div className="mb-3 flex items-center gap-2">
				<Cpu className="h-[18px] w-[18px]" style={{ color: PRIMARY }} aria-hidden />
				<span
					className="text-[11px] font-bold uppercase tracking-wide"
					style={{ color: ON_SURFACE_VARIANT }}
				>
					Smart Routing Engine
				</span>
			</div>
			<div className="space-y-3">
				<RoutingLine label="Voucher Deduction" amount={subtotal} currency={currency} />
				<RoutingLine
					label={`Tax (${taxPercent.toFixed(2)}%)`}
					amount={taxAmt}
					currency={currency}
					foreground={OUTLINE}
				/>
				<div className="flex items-center justify-between gap-3">
					<div className="flex items-center gap-1.5">
						<span className="text-sm" style={{ color: ON_SURFACE_VARIANT }}>
							Tier discount
						</span>
						{tierDiscountPercent > 0 ? (
							<span
								className="rounded-full px-2 py-0.5 text-[9px] font-bold"
								style={{ color: PRIMARY_CONTAINER, backgroundColor: 'rgba(0,75,195,0.1)' }}
							>
								{beamioTierDiscountPercentLabel(tierDiscountPercent)}%
							</span>
						) : null}
					</div>
					{tierDiscountPercent > 0 ? (
						<span className="inline-flex items-baseline gap-0.5 text-[#004bc3]">
							<span className="text-xs font-semibold">- </span>
							<MoneyParts parts={readBalanceFormatMoney(discAmt, currency)} size="md" />
						</span>
					) : (
						<span className="text-sm font-medium text-slate-400">—</span>
					)}
				</div>
				<div className="h-px pt-0.5" style={{ backgroundColor: 'rgba(195,198,214,0.35)' }} />
				<RoutingLine label="Tip" amount={tip} currency={currency} />
			</div>
		</div>
	)
}
