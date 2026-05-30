import { Check, Gift, Loader2 } from 'lucide-react'
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
import {
	merchantCouponRowId,
	readBalanceHasCouponClaimContext,
} from '@/utils/readBalanceCouponClaim'

const TOP_UP_BLUE = '#1562f0'
const CLAIM_GRADIENT = 'linear-gradient(to bottom right, rgb(255,132,36), rgb(255,71,87))'

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

function OwnedCouponTrailing({
	balance,
	loading,
	disabled,
	onConsume,
	showClaimedSuccess,
}: {
	balance: string
	loading?: boolean
	disabled?: boolean
	onConsume?: () => void
	showClaimedSuccess?: boolean
}) {
	return (
		<div className="flex items-center gap-2">
			<span
				className="rounded-full px-2.5 py-1.5 font-mono text-xs font-bold"
				style={{ backgroundColor: 'rgba(0,0,0,0.22)', color: '#fff' }}
			>
				x{balance}
			</span>
			{showClaimedSuccess ? (
				<span className="inline-flex items-center justify-center rounded-full bg-emerald-500 px-2.5 py-1.5">
					<Check className="h-4 w-4 text-white" aria-hidden />
				</span>
			) : (
				<button
					type="button"
					onClick={onConsume}
					disabled={disabled || loading}
					className="rounded-full px-2.5 py-1.5 text-[11px] font-semibold text-white disabled:cursor-not-allowed disabled:opacity-55"
					style={{ backgroundColor: TOP_UP_BLUE }}
				>
					{loading ? (
						<Loader2 className="h-4 w-4 animate-spin" aria-hidden />
					) : (
						'Consume'
					)}
				</button>
			)}
		</div>
	)
}

function ClaimCouponButton({
	loading,
	disabled,
	onClick,
	succeeded,
}: {
	loading?: boolean
	disabled?: boolean
	onClick?: () => void
	succeeded?: boolean
}) {
	if (succeeded) {
		return (
			<span className="inline-flex items-center justify-center rounded-full bg-emerald-500 px-2.5 py-1.5">
				<Check className="h-4 w-4 text-white" aria-hidden />
			</span>
		)
	}
	return (
		<button
			type="button"
			onClick={onClick}
			disabled={disabled || loading}
			className="inline-flex items-center justify-center rounded-full px-2.5 py-1.5 disabled:cursor-not-allowed disabled:opacity-55"
			style={{ background: CLAIM_GRADIENT }}
			aria-label="Claim coupon for member"
		>
			{loading ? (
				<Loader2 className="h-4 w-4 animate-spin text-white" aria-hidden />
			) : (
				<Gift className="h-4 w-4 text-white" aria-hidden />
			)}
		</button>
	)
}

export interface ReadBalanceCouponsSectionProps {
	assets: UIDAssetsResult
	activeCoupons: MerchantActiveIssuedCoupon[] | null | undefined
	claimInFlightId?: string | null
	claimSucceededId?: string | null
	consumeInFlightId?: string | null
	onClaimCoupon?: (coupon: MerchantClaimableCouponItem) => void
	onConsumeCoupon?: (coupon: MerchantCouponBalanceItem) => void
}

export function ReadBalanceCouponsSection({
	assets,
	activeCoupons,
	claimInFlightId = null,
	claimSucceededId = null,
	consumeInFlightId = null,
	onClaimCoupon,
	onConsumeCoupon,
}: ReadBalanceCouponsSectionProps) {
	const owned = assets.merchantCouponBalances ?? []
	const claimable = assets.merchantClaimableCoupons ?? []
	if (owned.length === 0 && claimable.length === 0) return null

	const hasClaimContext = readBalanceHasCouponClaimContext(assets)

	return (
		<div className="space-y-3">
			{owned.slice(0, 6).map((row) => {
				const rowId = merchantCouponRowId(row.cardAddress, row.tokenId)
				const canConsume =
					onConsumeCoupon &&
					(consumeInFlightId == null || consumeInFlightId === rowId)
				return (
					<OwnedCouponRow
						key={rowId}
						row={row}
						activeCoupons={activeCoupons}
						loading={consumeInFlightId === rowId}
						disabled={!canConsume}
						showClaimedSuccess={
							claimSucceededId === rowId && consumeInFlightId !== rowId
						}
						onConsume={() => onConsumeCoupon?.(row)}
					/>
				)
			})}
			{claimable.length > 0 ? (
				<div className="space-y-3">
					{claimable.slice(0, 6).map((row) => {
						const rowId = merchantCouponRowId(row.cardAddress, row.tokenId)
						const canTap =
							hasClaimContext &&
							onClaimCoupon &&
							(claimInFlightId == null || claimInFlightId === rowId)
						return (
							<ClaimableCouponRow
								key={rowId}
								row={row}
								activeCoupons={activeCoupons}
								loading={claimInFlightId === rowId}
								succeeded={claimSucceededId === rowId}
								disabled={!canTap}
								onClaim={() => onClaimCoupon?.(row)}
							/>
						)
					})}
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
	loading,
	disabled,
	showClaimedSuccess,
	onConsume,
}: {
	row: MerchantCouponBalanceItem
	activeCoupons: MerchantActiveIssuedCoupon[] | null | undefined
	loading?: boolean
	disabled?: boolean
	showClaimedSuccess?: boolean
	onConsume?: () => void
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
			trailing={
				<OwnedCouponTrailing
					balance={row.balance}
					loading={loading}
					disabled={disabled}
					showClaimedSuccess={showClaimedSuccess}
					onConsume={onConsume}
				/>
			}
		/>
	)
}

function ClaimableCouponRow({
	row,
	activeCoupons,
	loading,
	succeeded,
	disabled,
	onClaim,
}: {
	row: MerchantClaimableCouponItem
	activeCoupons: MerchantActiveIssuedCoupon[] | null | undefined
	loading?: boolean
	succeeded?: boolean
	disabled?: boolean
	onClaim?: () => void
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
			trailing={
				<ClaimCouponButton
					loading={loading}
					disabled={disabled}
					succeeded={succeeded}
					onClick={onClaim}
				/>
			}
		/>
	)
}

export { READ_BALANCE_SURFACE }
