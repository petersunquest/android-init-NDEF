import type { UIDAssetsResult } from '@/types/pos'
import type { CheckBalanceEntryQrClassification } from '@/utils/beamioQrIdentity'

export type CheckBalanceQrContext = CheckBalanceEntryQrClassification | null

/**
 * Legacy merchant cards (no cardSelfBurn): hide owned coupons unless entry QR is a
 * valid offline signed container. New cards always show owned coupons.
 */
export function assetsForCheckBalanceCouponDisplay(
	assets: UIDAssetsResult,
	opts: {
		merchantSupportsBurn: boolean | null
		qrContext: CheckBalanceQrContext
	},
): UIDAssetsResult {
	if (opts.merchantSupportsBurn !== false) {
		return assets
	}
	if (
		opts.qrContext?.kind === 'offline_container' &&
		opts.qrContext.offlineContainerValid === true
	) {
		return assets
	}
	if (!assets.merchantCouponBalances?.length) {
		return assets
	}
	return { ...assets, merchantCouponBalances: undefined }
}

export function checkBalanceHasStoredValidOfflineContainer(
	qrContext: CheckBalanceQrContext,
): qrContext is CheckBalanceEntryQrClassification & {
	kind: 'offline_container'
	offlineContainerValid: true
	offlineContainerPayload: Record<string, unknown>
} {
	return (
		qrContext?.kind === 'offline_container' &&
		qrContext.offlineContainerValid === true &&
		Boolean(qrContext.offlineContainerPayload)
	)
}
