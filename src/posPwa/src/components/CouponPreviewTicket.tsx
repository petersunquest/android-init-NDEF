import { Calendar, Clock } from 'lucide-react'
import type { ReactNode } from 'react'
import { CouponBannerImage } from '@/components/CouponBannerImage'
import { IpfsImg } from '@/components/IpfsImg'
import {
	couponExpiryUsesUrgentVariant,
	posCouponExpiryPresentation,
	shouldShowCouponExpiryPill,
} from '@/utils/couponExpiry'
import type { CouponTicketTone } from '@/utils/couponTone'

const READ_BALANCE_SURFACE = '#F9F9FE'

export interface CouponPreviewTicketProps {
	title: string
	subtitle: string
	iconUrl?: string
	backgroundImageUrl?: string
	tone: CouponTicketTone
	validBeforeSec?: number | null
	trailing?: ReactNode
	punchBgClassName?: string
}

/** POS Read Balance — aligns iOS `POSBizCouponPreviewTicket` + SilentPassUI banner-outside metadata. */
export function CouponPreviewTicket({
	title,
	subtitle,
	iconUrl,
	backgroundImageUrl,
	tone,
	validBeforeSec,
	trailing,
	punchBgClassName = 'bg-[#F9F9FE]',
}: CouponPreviewTicketProps) {
	const banner = backgroundImageUrl?.trim() ?? ''
	const hasBanner = banner.length > 0
	const icon = hasBanner ? '' : iconUrl?.trim() ?? ''
	const expiry = posCouponExpiryPresentation(validBeforeSec ?? null)
	const showExpiryPill = shouldShowCouponExpiryPill(expiry.label)
	const expiryUrgent = couponExpiryUsesUrgentVariant(expiry.label)
	const ExpiryIcon = expiryUrgent ? Clock : Calendar

	const innerExpiryClass = expiryUrgent
		? 'bg-red-600 text-white shadow-sm shadow-red-900/25'
		: 'border border-white/25 bg-slate-950/65 text-white shadow-sm shadow-black/20 backdrop-blur-md'
	const externalExpiryClass = expiryUrgent
		? 'bg-red-600 text-white shadow-sm shadow-red-900/25'
		: 'border border-[#abadaf]/35 bg-[#eef1f3] text-[#595c5e]'

	const renderExpiryPill = (placement: 'inner' | 'external') => (
		<div
			className={`inline-flex max-w-full items-center gap-1.5 rounded-full px-2.5 py-1 text-[10px] font-black uppercase tracking-wide ${
				placement === 'external' ? externalExpiryClass : innerExpiryClass
			}`}
		>
			<ExpiryIcon className="h-3 w-3 shrink-0" strokeWidth={2.5} aria-hidden />
			<span className="truncate">{expiry.label}</span>
		</div>
	)

	const ticketFace = (
		<div
			className="relative min-h-[7.5rem] overflow-hidden rounded-[1.75rem] ring-1"
			style={{
				borderColor: tone.borderColor,
				background: hasBanner
					? undefined
					: `linear-gradient(to bottom right, ${tone.gradientStart}, ${tone.gradientEnd})`,
			}}
		>
			{hasBanner ? (
				<CouponBannerImage src={banner} />
			) : (
				<>
					<div
						className="pointer-events-none absolute inset-0 opacity-[0.12]"
						style={{
							backgroundImage:
								'repeating-linear-gradient(-26deg, #fff 0, #fff 1px, transparent 1px, transparent 8px)',
						}}
						aria-hidden
					/>
					<div
						className="pointer-events-none absolute inset-0 bg-gradient-to-br from-white/15 via-transparent to-black/30"
						aria-hidden
					/>
				</>
			)}

			<div
				className={`relative z-[1] flex min-h-[7.5rem] items-center gap-3 px-5 py-3.5 ${
					hasBanner ? 'pr-5' : 'pr-4'
				}`}
			>
				{!hasBanner && icon ? (
					<div
						className="flex h-12 w-12 shrink-0 items-center justify-center overflow-hidden rounded-full border"
						style={{
							borderColor: 'rgba(255,255,255,0.4)',
							backgroundColor: tone.iconBackdrop,
						}}
					>
						<IpfsImg src={icon} alt="" className="h-full w-full object-cover" draggable={false} />
					</div>
				) : null}

				{!hasBanner ? (
					<div className="min-w-0 flex-1">
						<p
							className="truncate text-[17px] font-bold leading-tight"
							style={{ color: tone.primaryText }}
						>
							{title}
						</p>
						<p
							className="mt-0.5 truncate text-sm font-semibold"
							style={{ color: tone.secondaryText }}
						>
							{subtitle}
						</p>
						{showExpiryPill ? <div className="mt-2">{renderExpiryPill('inner')}</div> : null}
					</div>
				) : null}

				{!hasBanner && trailing ? <div className="shrink-0">{trailing}</div> : null}
			</div>
		</div>
	)

	const ticketShell = (
		<div className="relative w-full rounded-[1.75rem]">
			<div
				className={`pointer-events-none absolute left-0 top-1/2 z-20 h-9 w-9 -translate-x-1/2 -translate-y-1/2 rounded-full ${punchBgClassName}`}
				aria-hidden
			/>
			<div
				className={`pointer-events-none absolute right-0 top-1/2 z-20 h-9 w-9 translate-x-1/2 -translate-y-1/2 rounded-full ${punchBgClassName}`}
				aria-hidden
			/>
			{ticketFace}
		</div>
	)

	if (hasBanner) {
		return (
			<div className="relative w-full">
				{ticketShell}
				<div className="mt-3 space-y-2">
					<div className="flex items-start gap-3">
						<div className="min-w-0 flex-1 space-y-0.5">
							<p className="truncate text-[17px] font-extrabold leading-tight text-[#2c2f31]">
								{title}
							</p>
							<p className="truncate text-sm font-semibold text-[#595c5e]">{subtitle}</p>
						</div>
						{trailing ? <div className="shrink-0 self-center">{trailing}</div> : null}
					</div>
					{showExpiryPill ? renderExpiryPill('external') : null}
				</div>
			</div>
		)
	}

	return ticketShell
}

export { READ_BALANCE_SURFACE }
