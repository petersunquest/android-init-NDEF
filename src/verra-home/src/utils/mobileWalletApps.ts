/**
 * Mobile wallet “installed” hints for verra-home USDC pages.
 *
 * Web cannot enumerate installed native apps. We combine:
 * - Injected EIP-1193 flags when page runs inside a wallet in-app browser
 * - Short custom-scheme probes (iframe + visibility/blur) on capable mobile browsers
 * - sessionStorage cache (per tab) to avoid re-probing on every navigation
 */

const CACHE_PREFIX = 'verra.walletInstalled.'

export type MobileWalletId = 'metamask' | 'okx' | 'base' | 'tp'

export type MobileWalletProbeResult = Record<MobileWalletId, boolean>

const PROBE_SCHEMES: Record<MobileWalletId, readonly string[]> = {
	metamask: ['metamask://'],
	okx: ['okx://wallet/', 'okx://'],
	base: ['base://', 'cbwallet://', 'coinbase://'],
	tp: ['tpdapp://', 'tpoutside://'],
}

function readCache(id: MobileWalletId): boolean | null {
	try {
		const v = sessionStorage.getItem(CACHE_PREFIX + id)
		if (v === '1') return true
		if (v === '0') return false
	} catch {
		/* private mode */
	}
	return null
}

function writeCache(id: MobileWalletId, installed: boolean) {
	try {
		sessionStorage.setItem(CACHE_PREFIX + id, installed ? '1' : '0')
	} catch {
		/* ignore */
	}
}

function getEthereumProvidersList(): NonNullable<typeof window.ethereum>[] {
	const eth = typeof window !== 'undefined' ? window.ethereum : undefined
	if (!eth) return []
	const multi = (eth as unknown as { providers?: NonNullable<typeof window.ethereum>[] }).providers
	if (Array.isArray(multi) && multi.length > 0) return multi.filter(Boolean)
	return [eth]
}

export function isMobileDeviceForWalletApps(): boolean {
	if (typeof navigator === 'undefined') return false
	const ua = navigator.userAgent || ''
	const coarse =
		typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(pointer: coarse)').matches
	if (/Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(ua)) return true
	if (coarse && !/Windows NT|Macintosh|X11|Linux x86_64/i.test(ua)) return true
	return false
}

export function isIosLikeMobile(): boolean {
	if (typeof navigator === 'undefined') return false
	if (!isMobileDeviceForWalletApps()) return false
	return /iPhone|iPad|iPod/i.test(navigator.userAgent || '')
}

/** True when UI runs inside that wallet’s in-app browser (treat as “this wallet is active”). */
export function injectedWalletFlags(): MobileWalletProbeResult {
	const list = getEthereumProvidersList()
	const metamask = list.some((p) => !!p?.isMetaMask)
	const base = list.some((p) => !!(p as { isCoinbaseWallet?: boolean }).isCoinbaseWallet)
	const okx = list.some(
		(p) =>
			!!(p as { isOkxWallet?: boolean }).isOkxWallet || !!(p as { isOKExWallet?: boolean }).isOKExWallet
	)
	const tp = list.some(
		(p) =>
			!!(p as { isTokenPocket?: boolean }).isTokenPocket ||
			!!(p as { isTP?: boolean }).isTP ||
			!!(p as { isTokenPocketProvider?: boolean }).isTokenPocketProvider
	)
	return { metamask, okx, base, tp }
}

function probeCustomSchemeOnceDeep(schemeUrl: string, timeoutMs: number): Promise<boolean> {
	return new Promise((resolve) => {
		let settled = false
		const finish = (v: boolean) => {
			if (settled) return
			settled = true
			window.clearTimeout(timer)
			document.removeEventListener('visibilitychange', onVis)
			window.removeEventListener('pagehide', onPh)
			window.removeEventListener('blur', onBlur)
			resolve(v)
		}
		const onVis = () => {
			if (document.visibilityState === 'hidden') finish(true)
		}
		const onPh = () => finish(true)
		const onBlur = () => finish(true)
		const timer = window.setTimeout(() => finish(false), timeoutMs)
		document.addEventListener('visibilitychange', onVis)
		window.addEventListener('pagehide', onPh)
		window.addEventListener('blur', onBlur)

		const iframe = document.createElement('iframe')
		iframe.style.cssText =
			'position:fixed;left:-9999px;top:-9999px;width:1px;height:1px;border:0;opacity:0;pointer-events:none'
		iframe.src = schemeUrl
		document.body.appendChild(iframe)
		window.setTimeout(() => {
			try {
				iframe.remove()
			} catch {
				/* ignore */
			}
		}, Math.min(timeoutMs, 750))
	})
}

/** Sequential probes to reduce parallel iframe noise. */
export async function probeMobileWalletInstallations(
	order: readonly MobileWalletId[] = ['metamask', 'okx', 'base', 'tp']
): Promise<MobileWalletProbeResult> {
	const out: MobileWalletProbeResult = { metamask: false, okx: false, base: false, tp: false }
	if (typeof document === 'undefined' || typeof window === 'undefined') return out
	for (const id of order) {
		const cached = readCache(id)
		if (cached === true) {
			out[id] = true
			continue
		}
		if (cached === false) continue
		let ok = false
		for (const scheme of PROBE_SCHEMES[id]) {
			ok = await probeCustomSchemeOnceDeep(scheme, 950)
			if (ok) break
		}
		out[id] = ok
		writeCache(id, ok)
		await new Promise((r) => setTimeout(r, 120))
	}

	/**
	 * iOS Safari frequently blocks passive custom-scheme probes without user gesture.
	 * Avoid false-negative hiding on iPhone/iPad by keeping expected choices visible.
	 */
	if (isIosLikeMobile() && !out.metamask && !out.okx && !out.base && !out.tp) {
		out.metamask = true
		out.okx = true
		out.base = true
		out.tp = true
	}
	return out
}

/** Universal / app links to open this exact page inside each wallet. */
export function buildMobileWalletDappLinks(): Record<MobileWalletId, string> {
	const host = typeof window !== 'undefined' ? window.location.host : ''
	const path = typeof window !== 'undefined' ? window.location.pathname : ''
	const search = typeof window !== 'undefined' ? window.location.search : ''
	const httpsUrl = `https://${host}${path}${search}`
	const mmTail = `${host}${path}${search}`
	const okxDeeplink = `okx://wallet/dapp/url?dappUrl=${encodeURIComponent(httpsUrl)}`
	const tpParams = encodeURIComponent(JSON.stringify({ url: httpsUrl, chain: 'ETH', source: 'verra' }))

	return {
		metamask: `https://metamask.app.link/dapp/${mmTail}`,
		// iOS Safari compatibility: prefer OKX universal link wrapping official deeplink.
		okx: `https://web3.okx.com/download?deeplink=${encodeURIComponent(okxDeeplink)}`,
		base: `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(httpsUrl)}`,
		tp: `tpdapp://open?params=${tpParams}`,
	}
}

/**
 * iOS Safari: Base Wallet universal link may only wake app (stay on Home) on some versions/devices.
 * This actively tries deep-link into wallet browser first, then falls back to universal link.
 * Must be called from a direct user click/tap handler.
 */
export function openBaseWalletDappWithFallback(): void {
	if (typeof window === 'undefined' || typeof document === 'undefined') return
	const host = window.location.host
	const path = window.location.pathname
	const search = window.location.search
	const httpsUrl = `https://${host}${path}${search}`
	const deep = `cbwallet://dapp?url=${encodeURIComponent(httpsUrl)}`
	const fallback = `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(httpsUrl)}`

	let leftPage = false
	const onVis = () => {
		if (document.visibilityState === 'hidden') leftPage = true
	}
	const onPh = () => {
		leftPage = true
	}
	const onBlur = () => {
		leftPage = true
	}
	document.addEventListener('visibilitychange', onVis)
	window.addEventListener('pagehide', onPh)
	window.addEventListener('blur', onBlur)

	window.location.href = deep
	window.setTimeout(() => {
		document.removeEventListener('visibilitychange', onVis)
		window.removeEventListener('pagehide', onPh)
		window.removeEventListener('blur', onBlur)
		if (!leftPage) {
			window.location.href = fallback
		}
	}, 900)
}
