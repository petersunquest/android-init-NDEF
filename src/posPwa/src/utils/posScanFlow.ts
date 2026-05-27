import {
	cancelCashTreesPhysicalCardBind,
	hasCashTreesScanBridge,
	launchCashTreesQrScan,
	listenCashTreesNfc,
	listenCashTreesQr,
	newCashTreesScanRequestId,
	nfcErrorMessage,
	qrErrorMessage,
	shouldAutoLaunchQrAfterNfcFailure,
	startCashTreesPhysicalCardBind,
	type CashTreesNfcDetail,
	type CashTreesQrDetail,
} from '@/bridge/cashTreesScanBridge'
import {
	customerIdentityHasTarget,
	parseCustomerIdentity,
	type CustomerIdentity,
} from '@/utils/beamioQrIdentity'

export type PosScanFlowResult =
	| { status: 'nfc'; detail: CashTreesNfcDetail }
	| { status: 'qr'; identity: CustomerIdentity }
	| { status: 'aborted' }
	| { status: 'error'; message: string }

function waitForNfcEvent(): Promise<
	| { kind: 'success'; detail: CashTreesNfcDetail }
	| { kind: 'dismissed' }
	| { kind: 'error'; message: string }
> {
	return new Promise((resolve) => {
		let settled = false
		const finish = (
			value:
				| { kind: 'success'; detail: CashTreesNfcDetail }
				| { kind: 'dismissed' }
				| { kind: 'error'; message: string },
		) => {
			if (settled) return
			settled = true
			cleanup()
			resolve(value)
		}

		const cleanup = listenCashTreesNfc((detail) => {
			if (!detail.ok) {
				if (shouldAutoLaunchQrAfterNfcFailure(detail.error)) {
					finish({ kind: 'dismissed' })
					return
				}
				cancelCashTreesPhysicalCardBind()
				finish({ kind: 'error', message: nfcErrorMessage(detail.error) })
				return
			}
			cancelCashTreesPhysicalCardBind()
			finish({ kind: 'success', detail })
		})

		startCashTreesPhysicalCardBind()
	})
}

function waitForQrEvent(): Promise<
	| { kind: 'success'; text: string }
	| { kind: 'cancelled' }
	| { kind: 'error'; message: string }
> {
	return new Promise((resolve) => {
		let settled = false
		const requestId = newCashTreesScanRequestId()

		const finish = (
			value:
				| { kind: 'success'; text: string }
				| { kind: 'cancelled' }
				| { kind: 'error'; message: string },
		) => {
			if (settled) return
			settled = true
			cleanup()
			resolve(value)
		}

		const cleanup = listenCashTreesQr((detail: CashTreesQrDetail) => {
			if (detail.action !== 'scanQr') return
			if (detail.requestId && detail.requestId !== requestId) return
			if (!detail.ok) {
				if (detail.error === 'cancelled') {
					finish({ kind: 'cancelled' })
					return
				}
				finish({ kind: 'error', message: qrErrorMessage(detail.error) })
				return
			}
			const text = detail.text?.trim() ?? ''
			if (!text) {
				finish({ kind: 'error', message: 'QR scan returned empty content.' })
				return
			}
			finish({ kind: 'success', text })
		})

		launchCashTreesQrScan(requestId)
	})
}

/** Native NFC → (dismiss) native QR. Shared by Check Balance and Top-up. */
export async function runPosCustomerScanFlow(): Promise<PosScanFlowResult> {
	if (!hasCashTreesScanBridge()) {
		return {
			status: 'error',
			message: 'NFC and QR require the CashTrees native app WebView.',
		}
	}

	const nfc = await waitForNfcEvent()
	if (nfc.kind === 'success') {
		return { status: 'nfc', detail: nfc.detail }
	}
	if (nfc.kind === 'error') {
		return { status: 'error', message: nfc.message }
	}

	const qr = await waitForQrEvent()
	if (qr.kind === 'cancelled') {
		return { status: 'aborted' }
	}
	if (qr.kind === 'error') {
		return { status: 'error', message: qr.message }
	}

	const identity = parseCustomerIdentity(qr.text)
	if (!identity || !customerIdentityHasTarget(identity)) {
		return {
			status: 'error',
			message: 'Cannot parse QR. Scan a beamio.app link or Scan to Pay code.',
		}
	}
	return { status: 'qr', identity }
}

export function cancelPosCustomerScan(): void {
	cancelCashTreesPhysicalCardBind()
}
