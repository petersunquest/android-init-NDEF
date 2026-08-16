/**
 * Embedded PWA OTA (iOS WKWebView + Android WebViewAssetLoader).
 * Feature-detect bridge methods before calling.
 */

export type EmbeddedPwaUpdateDetail = {
	currentVer: string
	pendingVer: string
}

export type ApplyEmbeddedPwaUpdateDetail = {
	ok: boolean
	ver?: string
	error?: string
}

const IOS_BRIDGE_EVENT = 'cashtreesios'
const ANDROID_BRIDGE_EVENT = 'cashtreesandroid'

function isIosEmbeddedPwaBridgeReady(): boolean {
	if (typeof window === 'undefined') return false
	return typeof window.CashTreesIOS?.applyEmbeddedPwaUpdate === 'function'
}

function isAndroidEmbeddedPwaBridgeReady(): boolean {
	if (typeof window === 'undefined') return false
	return typeof window.CashTreesAndroid?.applyEmbeddedPwaUpdate === 'function'
}

/** True when either native shell injected embedded PWA OTA bridge methods. */
export function isEmbeddedPwaOtaSupported(): boolean {
	return isIosEmbeddedPwaBridgeReady() || isAndroidEmbeddedPwaBridgeReady()
}

export function readEmbeddedPwaVersion(): string {
	if (isIosEmbeddedPwaBridgeReady()) {
		return window.CashTreesIOS?.getEmbeddedPwaVersion?.() ?? ''
	}
	if (isAndroidEmbeddedPwaBridgeReady()) {
		return window.CashTreesAndroid?.getEmbeddedPwaVersion?.() ?? ''
	}
	return ''
}

export function readEmbeddedPwaPendingVersion(): string {
	if (isIosEmbeddedPwaBridgeReady()) {
		return window.CashTreesIOS?.getEmbeddedPwaPendingVersion?.() ?? ''
	}
	if (isAndroidEmbeddedPwaBridgeReady()) {
		return window.CashTreesAndroid?.getEmbeddedPwaPendingVersion?.() ?? ''
	}
	return ''
}

export function requestEmbeddedPwaUpdateApply(): void {
	if (isIosEmbeddedPwaBridgeReady()) {
		window.CashTreesIOS?.applyEmbeddedPwaUpdate?.()
		return
	}
	if (isAndroidEmbeddedPwaBridgeReady()) {
		window.CashTreesAndroid?.applyEmbeddedPwaUpdate?.()
	}
}

function subscribeBridgeEvent(
	eventName: string,
	predicate: (detail: Record<string, unknown>) => boolean,
	listener: (detail: Record<string, unknown>) => void,
): () => void {
	const onEvent = (event: Event) => {
		const detail = (event as CustomEvent).detail as Record<string, unknown>
		if (!detail || !predicate(detail)) return
		listener(detail)
	}
	window.addEventListener(eventName, onEvent)
	return () => window.removeEventListener(eventName, onEvent)
}

export function subscribeEmbeddedPwaUpdateAvailable(
	listener: (detail: EmbeddedPwaUpdateDetail) => void,
): () => void {
	if (!isEmbeddedPwaOtaSupported()) return () => {}

	const handler = (detail: Record<string, unknown>) => {
		const pendingVer = typeof detail.pendingVer === 'string' ? detail.pendingVer : ''
		if (!pendingVer) return
		listener({
			currentVer: typeof detail.currentVer === 'string' ? detail.currentVer : '',
			pendingVer,
		})
	}

	const predicate = (detail: Record<string, unknown>) =>
		detail.action === 'embeddedPwaUpdateAvailable'

	const offIos = isIosEmbeddedPwaBridgeReady()
		? subscribeBridgeEvent(IOS_BRIDGE_EVENT, predicate, handler)
		: () => {}
	const offAndroid = isAndroidEmbeddedPwaBridgeReady()
		? subscribeBridgeEvent(ANDROID_BRIDGE_EVENT, predicate, handler)
		: () => {}

	return () => {
		offIos()
		offAndroid()
	}
}

export function subscribeApplyEmbeddedPwaUpdateResult(
	listener: (detail: ApplyEmbeddedPwaUpdateDetail) => void,
): () => void {
	if (!isEmbeddedPwaOtaSupported()) return () => {}

	const handler = (detail: Record<string, unknown>) => {
		listener({
			ok: detail.ok === true,
			ver: typeof detail.ver === 'string' ? detail.ver : undefined,
			error: typeof detail.error === 'string' ? detail.error : undefined,
		})
	}

	const predicate = (detail: Record<string, unknown>) =>
		detail.action === 'applyEmbeddedPwaUpdate'

	const offIos = isIosEmbeddedPwaBridgeReady()
		? subscribeBridgeEvent(IOS_BRIDGE_EVENT, predicate, handler)
		: () => {}
	const offAndroid = isAndroidEmbeddedPwaBridgeReady()
		? subscribeBridgeEvent(ANDROID_BRIDGE_EVENT, predicate, handler)
		: () => {}

	return () => {
		offIos()
		offAndroid()
	}
}
