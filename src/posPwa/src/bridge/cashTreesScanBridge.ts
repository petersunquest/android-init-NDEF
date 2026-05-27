/** Native NFC / QR bridge — mirrors iOS `ContentView.swift` CashTreesIOS + Android `MainActivity.kt` CashTreesAndroid. */

export type CashTreesNfcStatus =
	| 'ready'
	| 'no_hardware'
	| 'nfc_disabled'
	| 'nfc_permission_denied'
	| 'no_bridge'

export interface CashTreesSunParams {
	uid: string
	e: string
	c: string
	m: string
}

export interface CashTreesNfcDetail {
	ok: boolean
	error?: string
	tagUidHex?: string
	queryUid?: string
	ndefUri?: string
	sun?: CashTreesSunParams
}

export interface CashTreesQrDetail {
	action?: string
	ok: boolean
	requestId?: string
	text?: string
	recoveryCode?: string
	error?: string
}

declare global {
	interface Window {
		CashTreesIOS?: {
			getNfcStatus?: () => string
			startPhysicalCardBind?: () => void
			cancelPhysicalCardBind?: () => void
			scanQr?: (payload: { requestId?: string }) => void
			openURL?: (payload: { url?: string }) => void
		}
		CashTreesAndroid?: {
			getNfcStatus?: () => string
			startPhysicalCardBind?: () => void
			cancelPhysicalCardBind?: () => void
			scanQr?: (requestId: string) => void
			openURL?: (url: string) => void
		}
	}
}

function iosBridge() {
	return window.CashTreesIOS
}

function androidBridge() {
	return window.CashTreesAndroid
}

export function hasCashTreesScanBridge(): boolean {
	return Boolean(iosBridge()?.startPhysicalCardBind ?? androidBridge()?.startPhysicalCardBind)
}

export function getCashTreesNfcStatus(): CashTreesNfcStatus {
	const raw = iosBridge()?.getNfcStatus?.() ?? androidBridge()?.getNfcStatus?.() ?? 'no_bridge'
	const v = String(raw).trim().toLowerCase()
	if (
		v === 'ready' ||
		v === 'no_hardware' ||
		v === 'nfc_disabled' ||
		v === 'nfc_permission_denied' ||
		v === 'no_bridge'
	) {
		return v
	}
	return hasCashTreesScanBridge() ? 'ready' : 'no_bridge'
}

export function startCashTreesPhysicalCardBind(): void {
	iosBridge()?.startPhysicalCardBind?.()
	androidBridge()?.startPhysicalCardBind?.()
}

export function cancelCashTreesPhysicalCardBind(): void {
	iosBridge()?.cancelPhysicalCardBind?.()
	androidBridge()?.cancelPhysicalCardBind?.()
}

export function launchCashTreesQrScan(requestId: string): void {
	const rid = requestId.trim()
	if (iosBridge()?.scanQr) {
		iosBridge()!.scanQr!({ requestId: rid })
		return
	}
	androidBridge()?.scanQr?.(rid)
}

const EXTERNAL_URL_SCHEMES = new Set(['http', 'https', 'mailto', 'tel'])

function isAllowedExternalUrl(raw: string): boolean {
	const trimmed = raw.trim()
	if (!trimmed) return false
	try {
		const u = new URL(trimmed)
		return EXTERNAL_URL_SCHEMES.has(u.protocol.replace(':', '').toLowerCase())
	} catch {
		return false
	}
}

/** Native shell → system browser; web → `window.open`. Mirrors iOS/Android `openURL` bridge. */
export function openExternalUrl(url: string): boolean {
	const trimmed = url.trim()
	if (!isAllowedExternalUrl(trimmed)) return false
	if (iosBridge()?.openURL) {
		iosBridge()!.openURL!({ url: trimmed })
		return true
	}
	if (androidBridge()?.openURL) {
		androidBridge()!.openURL!(trimmed)
		return true
	}
	window.open(trimmed, '_blank', 'noopener,noreferrer')
	return false
}

export function newCashTreesScanRequestId(): string {
	if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
		return crypto.randomUUID()
	}
	return `scan-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
}

export function listenCashTreesNfc(handler: (detail: CashTreesNfcDetail) => void): () => void {
	const fn = (e: Event) => {
		const detail = (e as CustomEvent<CashTreesNfcDetail>).detail
		if (detail && typeof detail === 'object') handler(detail)
	}
	window.addEventListener('cashtreesnfc', fn)
	return () => window.removeEventListener('cashtreesnfc', fn)
}

/** iOS dispatches `cashtreesios`; Android dispatches `cashtreesandroid` (same detail shape for scanQr). */
export function listenCashTreesQr(handler: (detail: CashTreesQrDetail) => void): () => void {
	const fn = (e: Event) => {
		const detail = (e as CustomEvent<CashTreesQrDetail>).detail
		if (detail && typeof detail === 'object') handler(detail)
	}
	window.addEventListener('cashtreesios', fn)
	window.addEventListener('cashtreesandroid', fn)
	return () => {
		window.removeEventListener('cashtreesios', fn)
		window.removeEventListener('cashtreesandroid', fn)
	}
}

export function nfcErrorMessage(error: string | undefined): string {
	switch ((error ?? '').trim().toLowerCase()) {
		case 'cancelled':
			return 'Scan cancelled.'
		case 'no_hardware':
			return 'This device has no NFC hardware.'
		case 'nfc_disabled':
			return 'NFC is disabled. Turn it on in Settings.'
		case 'nfc_permission_denied':
			return 'NFC permission was denied.'
		case 'unsupported_tag':
			return 'Unsupported NFC tag.'
		case 'empty_tag_uid':
			return 'Cannot read UID from this card.'
		default:
			return error?.trim() || 'NFC read failed.'
	}
}

export function qrErrorMessage(error: string | undefined): string {
	switch ((error ?? '').trim().toLowerCase()) {
		case 'cancelled':
			return 'Scan cancelled.'
		case 'camera_unavailable':
			return 'Camera is unavailable.'
		case 'camera_permission_denied':
			return 'Camera permission was denied.'
		case 'qr_not_found':
			return 'No QR code found.'
		default:
			return error?.trim() || 'QR scan failed.'
	}
}

/** iOS `handleScanSheetNfcDismissedByUser` / `armScanQrCameraFromNfcFallback` — user dismissed NFC or NFC unavailable. */
export function shouldAutoLaunchQrAfterNfcFailure(error: string | undefined): boolean {
	const e = (error ?? '').trim().toLowerCase()
	return (
		e === 'cancelled' ||
		e === 'no_hardware' ||
		e === 'nfc_disabled' ||
		e === 'nfc_permission_denied'
	)
}
