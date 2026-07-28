import { CheckCircle2 } from 'lucide-react'
import { ReadBalancePassHeroCard } from '@/components/ReadBalancePassHeroCard'
import type { ReadBalanceMoneyParts } from '@/utils/readBalanceDisplay'

const PAGE_BG = '#f9f9fe'
const PRIMARY_CONTAINER = '#004bc3'

/** iOS `paymentSuccessStandardPassHero` — Approved badge overlapping pass card. */
export function PosPaymentApprovedPassHero({
	memberDisplayName,
	memberNo,
	tierDisplayName,
	tierDiscountPercent,
	programCardDisplayName,
	tierCardBackgroundHex,
	cardMetadataImageUrl,
	balanceParts,
	balanceSubtitle,
}: {
	memberDisplayName: string
	memberNo: string
	tierDisplayName: string | null
	tierDiscountPercent: number | null
	programCardDisplayName: string
	tierCardBackgroundHex?: string
	cardMetadataImageUrl: string | null
	balanceParts: ReadBalanceMoneyParts
	balanceSubtitle: string | null
}) {
	return (
		<div className="relative w-full">
			<div className="pt-12">
				<ReadBalancePassHeroCard
					memberDisplayName={memberDisplayName}
					memberNo={memberNo}
					tierDisplayName={tierDisplayName}
					tierDiscountPercent={tierDiscountPercent}
					programCardDisplayName={programCardDisplayName}
					tierCardBackgroundHex={tierCardBackgroundHex}
					cardMetadataImageUrl={cardMetadataImageUrl}
					balanceParts={balanceParts}
					balanceSubtitle={balanceSubtitle}
				/>
			</div>
			<div className="absolute left-1/2 top-0 flex -translate-x-1/2 flex-col items-center gap-2">
				<div className="relative flex h-[68px] w-[68px] items-center justify-center">
					<span
						className="absolute inset-0 rounded-full bg-white"
						style={{ boxShadow: '0 0 0 4px ' + PAGE_BG }}
					/>
					<span
						className="relative flex h-14 w-14 items-center justify-center rounded-full text-white shadow-lg"
						style={{
							backgroundColor: PRIMARY_CONTAINER,
							boxShadow: '0 4px 12px rgba(0,75,195,0.35)',
						}}
					>
						<CheckCircle2 className="h-7 w-7" aria-hidden />
					</span>
				</div>
				<span
					className="text-[11px] font-bold uppercase tracking-[0.2em]"
					style={{ color: PRIMARY_CONTAINER }}
				>
					Approved
				</span>
			</div>
		</div>
	)
}
