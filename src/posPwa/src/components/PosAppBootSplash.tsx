import { POS_WEB_SURFACE_HEX } from '@/constants'

/**
 * App boot / Suspense fallback — solid WebView surface color, no chrome.
 * Bridges native LaunchScreen → PWA first paint (iOS `cashTreesWebSurfaceColor`).
 */
export function PosAppBootSplash() {
	return (
		<div
			className="h-dvh max-h-dvh w-full max-w-[100vw] overflow-hidden overscroll-none"
			style={{ backgroundColor: POS_WEB_SURFACE_HEX }}
			role="status"
			aria-busy="true"
			aria-label="Loading"
		/>
	)
}
