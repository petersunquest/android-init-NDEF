import type { UIDAssetsResult } from '@/types/pos'
import type { CheckBalanceEntryQrClassification } from '@/utils/beamioQrIdentity'
import { merchantCouponRowId } from '@/utils/readBalanceCouponClaim'

export type CheckBalanceQrContext = CheckBalanceEntryQrClassification | null

/**
 * NFC coupon workflow: physical tap, or QR wallet linked to API-hosted NFC key.
 *
 * - Physical NFC: `nfcScan` / SUN `uid`/`tagIdHex`
 * - QR + Link: `nfcApiHostedSigning` (+ enrich `uid`/`tagIdHex`) from getWalletAssets
 */
export function checkBalanceUsesNfcCouponWorkflow(opts: {
	nfcScan?: { uid?: string } | null
	assets?: Pick<UIDAssetsResult, 'uid' | 'tagIdHex' | 'nfcApiHostedSigning'> | null
}): boolean {
	if (opts.assets?.nfcApiHostedSigning === true) return true
	if (opts.nfcScan?.uid?.trim()) return true
	if (opts.assets?.uid?.trim()) return true
	if (opts.assets?.tagIdHex?.trim()) return true
	return false
}

/** @deprecated Prefer {@link checkBalanceUsesNfcCouponWorkflow}. */
export function checkBalanceEntryViaNfc(opts: {
	nfcScan?: { uid?: string } | null
	assets?: Pick<UIDAssetsResult, 'uid' | 'tagIdHex' | 'nfcApiHostedSigning'> | null
}): boolean {
	return checkBalanceUsesNfcCouponWorkflow(opts)
}

/**
 * Check Balance coupon list for display.
 *
 * - **NFC workflow** (`checkBalanceUsesNfcCouponWorkflow`): always show on-chain owned
 *   coupons. API can sign Claim with hosted NFC / Link key without Customer Pay QR.
 * - **Pure QR**: legacy merchant cards (no `cardSelfBurn`) hide owned coupons unless
 *   entry was a valid offline signed Pay QR.
 * - New cards (`merchantSupportsBurn !== false`): always show owned coupons.
 */
export function assetsForCheckBalanceCouponDisplay(
	assets: UIDAssetsResult,
	opts: {
		merchantSupportsBurn: boolean | null
		qrContext: CheckBalanceQrContext
		/** True when Check Balance uses NFC / API-hosted-signing coupon workflow. */
		entryViaNfc?: boolean
		/** After one Consume in this session, hide sibling owned coupons. */
		consumeSucceededId?: string | null
	},
): UIDAssetsResult {
	let next = assets
	const viaNfcWorkflow = opts.entryViaNfc === true
	if (!viaNfcWorkflow && opts.merchantSupportsBurn === false) {
		const allowOffline =
			opts.qrContext?.kind === 'offline_container' &&
			opts.qrContext.offlineContainerValid === true
		if (!allowOffline && assets.merchantCouponBalances?.length) {
			next = { ...assets, merchantCouponBalances: undefined }
		}
	}
	return assetsAfterOneCouponConsumedInSession(next, opts.consumeSucceededId ?? null)
}

/**
 * One Check Balance session → at most one Consume shown afterwards.
 * After success, drop every other owned coupon so cashiers do not retry with a
 * spent Pay QR / nonce.
 */
export function assetsAfterOneCouponConsumedInSession(
	assets: UIDAssetsResult,
	consumeSucceededId: string | null,
): UIDAssetsResult {
	if (!consumeSucceededId) return assets
	const owned = assets.merchantCouponBalances ?? []
	if (owned.length === 0) return assets
	const kept = owned.filter(
		(row) => merchantCouponRowId(row.cardAddress, row.tokenId) === consumeSucceededId,
	)
	return {
		...assets,
		merchantCouponBalances: kept.length > 0 ? kept : undefined,
	}
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
