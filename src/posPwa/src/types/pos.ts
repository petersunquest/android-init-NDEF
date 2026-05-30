/// <reference types="vite/client" />

export interface TerminalProfile {
	accountName?: string
	username?: string
	first_name?: string
	last_name?: string
	firstName?: string
	lastName?: string
	image?: string
	address?: string
}

export interface PosSessionState {
	walletAddress: string | null
	parentBeamioTag: string
	parentProfile: TerminalProfile | null
	terminalProfile: TerminalProfile | null
	adminProfile: TerminalProfile | null
	merchantInfraCard: string | null
	registeredBeamioTag: string | null
}

export interface PosHomeStats {
	charge: number | null
	topUp: number | null
	tips: number | null
	chargeUsdc: number | null
	tipsUsdc: number | null
}

export type PosNativeAction =
	| 'charge'
	| 'topup'
	| 'readBalance'
	| 'deductPoints'
	| 'history'
	| 'linkApp'
	| 'activeCoupons'

export interface PosLedgerResponse {
	ok?: boolean
	currency?: string
	chargeAmount?: number | string
	topUpAmount?: number | string
	tipsAmount?: number | string
	chargeUsdc?: number | string
	tipsUsdc?: number | string
}

export interface MyPosAddressResponse {
	ok?: boolean
	cardAddress?: string
	myPosAddress?: string
	merchantInfraCard?: string
	currency?: string
	terminalMetadata?: {
		handle?: string
		deviceName?: string
	}
}

export interface CardAdminInfoResponse {
	ok?: boolean
	/** Not returned by API; use resolvePosTerminalAccessAllowed / walletHasTrustedInfraPosHomeAccess. */
	isAdmin?: boolean
	upperAdmin?: string | null
	owner?: string | null
	admins?: string[]
	metadatas?: string[]
	parents?: string[]
}

export interface MerchantActiveCoupon {
	seriesId?: string
	title?: string
	subtitle?: string
}

export interface MerchantCouponBalanceItem {
	cardAddress: string
	couponId: string
	tokenId: string
	title: string
	balance: string
	requiresRedeemCode: boolean
}

export interface MerchantClaimableCouponItem {
	cardAddress: string
	couponId: string
	tokenId: string
	title: string
	requiresRedeemCode: boolean
}

export interface ReadBalanceNftItem {
	tokenId: string
	attribute?: string
	tier?: string
}

export interface ReadBalanceCardItem {
	cardAddress: string
	cardName: string
	cardType?: string
	points: string
	points6: string
	cardCurrency: string
	cardBackground?: string
	cardImage?: string
	tierName?: string
	tierDescription?: string
	tierDiscountPercent?: number
	chargeRewardPoints6?: string
	primaryMemberTokenId?: string
	nfts?: ReadBalanceNftItem[]
}

/** From getWalletAssets / getUIDAssets — prepare oracle for charge split. */
export interface UIDAssetsResult {
	ok: boolean
	error?: string
	address?: string
	aaAddress?: string
	beamioTag?: string
	uid?: string
	tagIdHex?: string
	cardAddress?: string
	points?: string
	points6?: string
	usdcBalance?: string
	caddBalance?: string
	cardCurrency?: string
	unitPriceUSDC6?: string
	primaryMemberTokenId?: string
	chargeRewardPoints6?: string
	posLastTopupAt?: string
	posLastTopupUsdcE6?: string
	posLastTopupPointsE6?: string
	cards?: ReadBalanceCardItem[]
	nfts?: ReadBalanceNftItem[]
	merchantCouponBalances?: MerchantCouponBalanceItem[]
	merchantClaimableCoupons?: MerchantClaimableCouponItem[]
}
