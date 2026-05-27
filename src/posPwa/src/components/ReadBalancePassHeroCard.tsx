import { CreditCard } from 'lucide-react'
import { useState } from 'react'
import {
	beamioTierDiscountPercentLabel,
	readBalancePassHeroPalette,
	type ReadBalanceMoneyParts,
} from '@/utils/readBalanceDisplay'

export interface ReadBalancePassHeroCardProps {
	memberDisplayName: string
	memberNo: string
	tierDisplayName: string | null
	tierDiscountPercent: number | null
	programCardDisplayName: string
	tierCardBackgroundHex: string | undefined
	cardMetadataImageUrl: string | null
	balanceParts: ReadBalanceMoneyParts
	balanceSubtitle: string | null
}

export function ReadBalancePassHeroCard({
	memberDisplayName,
	memberNo,
	tierDisplayName,
	tierDiscountPercent,
	programCardDisplayName,
	tierCardBackgroundHex,
	cardMetadataImageUrl,
	balanceParts,
	balanceSubtitle,
}: ReadBalancePassHeroCardProps) {
	const [imgFailed, setImgFailed] = useState(false)
	const tone = readBalancePassHeroPalette(tierCardBackgroundHex)
	const showImage = cardMetadataImageUrl && !imgFailed

	return (
		<div
			className="relative aspect-[1.6/1] w-full overflow-hidden rounded-3xl shadow-[0_6px_12px_rgba(0,0,0,0.2)]"
			style={{
				background: `linear-gradient(to bottom right, ${tone.gradientStart}, ${tone.gradientEnd})`,
			}}
		>
			<div
				className="pointer-events-none absolute -right-[72px] -top-[72px] h-[180px] w-[180px] rounded-full"
				style={{ backgroundColor: tone.decorativeCircle }}
			/>
			<div className="relative flex h-full flex-col p-6">
				<div className="flex items-start gap-2">
					<h2
						className="min-w-0 flex-1 text-[22px] font-black leading-tight"
						style={{ color: tone.primaryText }}
					>
						{memberDisplayName}
					</h2>
					<div className="shrink-0 text-right">
						<p
							className="font-mono text-sm font-bold"
							style={{ color: tone.primaryText }}
						>
							{memberNo || '—'}
						</p>
						{tierDisplayName ? (
							<p className="mt-1 text-xs font-medium" style={{ color: tone.secondaryText }}>
								{tierDisplayName}
							</p>
						) : null}
						{tierDiscountPercent != null && tierDiscountPercent > 0 ? (
							<p className="mt-0.5 text-[11px] font-medium" style={{ color: tone.tertiaryText }}>
								{beamioTierDiscountPercentLabel(tierDiscountPercent)}% discount
							</p>
						) : null}
					</div>
				</div>
				<div className="mt-auto space-y-2">
					<p className="text-[11px] font-semibold leading-snug" style={{ color: tone.secondaryText }}>
						{programCardDisplayName}
					</p>
					<div className="flex items-end gap-0.5">
						{balanceParts.prefix ? (
							<span className="pb-0.5 text-lg font-bold" style={{ color: tone.primaryText }}>
								{balanceParts.prefix}
							</span>
						) : null}
						<span
							className="font-mono text-[32px] font-bold tracking-tight"
							style={{ color: tone.primaryText }}
						>
							{balanceParts.mid}
						</span>
						{balanceParts.suffix ? (
							<span className="pb-0.5 text-lg font-bold" style={{ color: tone.primaryText }}>
								{balanceParts.suffix}
							</span>
						) : null}
					</div>
					{balanceSubtitle ? (
						<p
							className="font-mono text-xs font-semibold"
							style={{ color: tone.secondaryText }}
						>
							{balanceSubtitle}
						</p>
					) : null}
				</div>
			</div>
			<div
				className="absolute bottom-3 right-[22px] flex h-12 w-12 items-center justify-center overflow-hidden rounded-full"
				style={{
					border: `1px solid ${tone.avatarBorder}`,
					backgroundColor: tone.avatarBackdrop,
				}}
			>
				{showImage ? (
					<img
						src={cardMetadataImageUrl!}
						alt=""
						className="h-full w-full object-cover"
						onError={() => setImgFailed(true)}
					/>
				) : (
					<CreditCard className="h-6 w-6" style={{ color: tone.walletIconTint }} aria-hidden />
				)}
			</div>
		</div>
	)
}
