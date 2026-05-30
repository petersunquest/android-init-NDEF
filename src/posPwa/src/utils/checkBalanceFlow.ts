import { fetchUIDAssets, fetchWalletAssetsForRead } from '@/api/beamioApi'
import type { UIDAssetsResult } from '@/types/pos'
import { isNfcUid14Hex, normalizeNfcUid14 } from '@/utils/nfcUid'
import { cancelPosCustomerScan, runPosCustomerScanFlow } from '@/utils/posScanFlow'

export type CheckBalanceNfcScanContext = {
	uid: string
	sun: { e: string; c: string; m: string }
}

export type CheckBalanceFlowResult =
	| { status: 'success'; assets: UIDAssetsResult; nfcScan?: CheckBalanceNfcScanContext }
	| { status: 'aborted' }
	| { status: 'error'; message: string }

async function queryAssetsFromNfc(
	detail: { queryUid?: string; tagUidHex?: string; sun?: { e: string; c: string; m: string } },
	merchantInfraCard: string,
): Promise<CheckBalanceFlowResult> {
	const uid = (detail.queryUid ?? detail.tagUidHex ?? '').trim()
	if (!uid) {
		return { status: 'error', message: 'Cannot read UID from this card.' }
	}
	const result = await fetchUIDAssets({
		uid,
		merchantInfraCard,
		sun: detail.sun,
	})
	if (!result) {
		return { status: 'error', message: 'Balance query failed. Check network and try again.' }
	}
	if (!result.ok) {
		return { status: 'error', message: result.error?.trim() || 'Query failed.' }
	}
	const nfcScan =
		detail.sun && isNfcUid14Hex(uid)
			? { uid: normalizeNfcUid14(uid), sun: detail.sun }
			: undefined
	return {
		status: 'success',
		assets: result,
		nfcScan,
	}
}

async function queryAssetsFromQrIdentity(
	identity: { beamioTag?: string; wallet?: string },
	merchantInfraCard: string,
): Promise<CheckBalanceFlowResult> {
	let result: UIDAssetsResult | null = null
	if (identity.beamioTag?.trim()) {
		result = await fetchUIDAssets({
			uid: identity.beamioTag.trim(),
			merchantInfraCard,
		})
	} else if (identity.wallet) {
		result = await fetchWalletAssetsForRead({
			wallet: identity.wallet,
			merchantInfraCard,
		})
	}
	if (!result) {
		return { status: 'error', message: 'Balance query failed. Check network and try again.' }
	}
	if (!result.ok) {
		return { status: 'error', message: result.error?.trim() || 'Query failed.' }
	}
	return { status: 'success', assets: result }
}

/** Headless Check Balance: native NFC → (dismiss) native QR → result or home. */
export async function runCheckBalanceFlow(merchantInfraCard: string): Promise<CheckBalanceFlowResult> {
	const infra = merchantInfraCard.trim()
	if (!infra) {
		return { status: 'error', message: 'Terminal program card is not configured.' }
	}

	const scan = await runPosCustomerScanFlow()
	if (scan.status === 'nfc') {
		return queryAssetsFromNfc(scan.detail, infra)
	}
	if (scan.status === 'qr') {
		return queryAssetsFromQrIdentity(scan.identity, infra)
	}
	if (scan.status === 'aborted') {
		return { status: 'aborted' }
	}
	return { status: 'error', message: scan.message }
}

export { cancelPosCustomerScan as cancelCheckBalanceFlow }
