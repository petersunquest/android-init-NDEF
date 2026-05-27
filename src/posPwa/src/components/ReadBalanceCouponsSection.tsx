import { Gift, Loader2 } from 'lucide-react'
import { CouponPreviewTicket, READ_BALANCE_SURFACE } from '@/components/CouponPreviewTicket'
import type {
	MerchantClaimableCouponItem,
	MerchantCouponBalanceItem,
	UIDAssetsResult,
} from '@/types/pos'
import {
	matchActiveIssuedCoupon,
	resolveCouponBackgroundHex,
	type MerchantActiveIssuedCoupon,
} from '@/utils/couponMetadata'
import { couponTicketToneFromHex } from '@/utils/couponTone'

const TOP_UP_BLUE = '#1562f0'

function couponVisuals(
	row: { cardAddress: string; couponId: string; tokenId: string; title: string },
	activeCoupons: MerchantActiveIssuedCoupon[] | null | undefined,
) {
	const match = matchActiveIssuedCoupon(
		activeCoupons,
		row.cardAddress,
		row.couponId,
		row.tokenId,
	)
	const bgHex = resolveCouponBackgroundHex(
		activeCoupons,
		row.couponId,
		row.tokenId,
		row.cardAddress,
	)
	const tone = couponTicketToneFromHex(match?.backgroundColorHex ?? bgHex, row.couponId)
	const rawSub = match?.subtitle?.trim() ?? ''
	const subtitle = rawSub || 'Add coupon details for members'
	return {
		match,
		tone,
		title: row.title.trim() || match?.displayTitle || 'Coupon',
		subtitle,
		iconUrl: match?.iconUrl,
		backgroundImageUrl: match?.backgroundImageUrl,
		validBeforeSec: match?.issuedNftValidBeforeSec,
	}
}

function OwnedCouponTrailing({ balance }: { balance: string }) {
	return (
		<div className="flex items-center gap-2">
			<span
				className="rounded-full px-2.5 py-1.5 font-mono text-xs font-bold"
				style={{ backgroundColor: 'rgba(0,0,0,0.22)', color: '#fff' }}
			>
				x{balance}
			</span>
			<span
				className="rounded-full px-2.5 py-1.5 text-[11px] font-semibold text-white opacity-90"
				style={{ backgroundColor: TOP_UP_BLUE }}
			>
				Consume
			</span>
		</div>
	)
}

function ClaimableCouponTrailing({ loading }: { loading?: boolean }) {
	return (
		<span
			className="inline-flex items-center justify-center rounded-full px-2.5 py-1.5"
			style={{
				background: `linear-gradient(to right, ${TOP_UP_BLUE}, #7c3aed)`,
			}}
		>
			{loading ? (
				<Loader2 className="h-4 w-4 animate-spin text-white" aria-hidden />
			) : (
				<Gift className="h-4 w-4 text-white" aria-hidden />
			)}
		</span>
	)
}

export interface ReadBalanceCouponsSectionProps {
	assets: UIDAssetsResult
	activeCoupons: MerchantActiveIssuedCoupon[] | null | undefined
}

export function ReadBalanceCouponsSection({
	assets,
	activeCoupons,
}: ReadBalanceCouponsSectionProps) {
	const owned = assets.merchantCouponBalances ?? []
	const claimable = assets.merchantClaimableCoupons ?? []
	if (owned.length === 0 && claimable.length === 0) return null

	const hasClaimContext = Boolean(
		assets.address?.trim().startsWith('0x') && assets.address.trim().length >= 10,
	)

	return (
		<div className="space-y-3">
			{owned.slice(0, 6).map((row) => (
				<OwnedCouponRow
					key={`${row.cardAddress}:${row.tokenId}`}
					row={row}
					activeCoupons={activeCoupons}
				/>
			))}
			{claimable.length > 0 ? (
				<div className="space-y-3">
					{claimable.slice(0, 6).map((row) => (
						<ClaimableCouponRow
							key={`${row.cardAddress}:${row.tokenId}`}
							row={row}
							activeCoupons={activeCoupons}
						/>
					))}
					{!hasClaimContext ? (
						<p className="text-[10px] font-medium text-[#737685]">
							Claim requires member wallet or NFC card.
						</p>
					) : null}
				</div>
			) : null}
		</div>
	)
}

function OwnedCouponRow({
	row,
	activeCoupons,
}: {
	row: MerchantCouponBalanceItem
	activeCoupons: MerchantActiveIssuedCoupon[] | null | undefined
}) {
	const v = couponVisuals(row, activeCoupons)
	return (
		<CouponPreviewTicket
			title={v.title}
			subtitle={v.subtitle}
			iconUrl={v.iconUrl}
			backgroundImageUrl={v.backgroundImageUrl}
			tone={v.tone}
			validBeforeSec={v.validBeforeSec}
			punchBgClassName="bg-[#F9F9FE]"
			trailing={<OwnedCouponTrailing balance={row.balance} />}
		/>
	)
}

function ClaimableCouponRow({
	row,
	activeCoupons,
}: {
	row: MerchantClaimableCouponItem
	activeCoupons: MerchantActiveIssuedCoupon[] | null | undefined
}) {
	const v = couponVisuals(row, activeCoupons)
	return (
		<CouponPreviewTicket
			title={v.title}
			subtitle={v.subtitle}
			iconUrl={v.iconUrl}
			backgroundImageUrl={v.backgroundImageUrl}
			tone={v.tone}
			validBeforeSec={v.validBeforeSec}
			punchBgClassName="bg-[#F9F9FE]"
			trailing={<ClaimableCouponTrailing />}
		/>
	)
}

export { READ_BALANCE_SURFACE }
