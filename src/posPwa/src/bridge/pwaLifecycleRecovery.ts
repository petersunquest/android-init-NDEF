/**
 * Browser-side recovery for the POS PWA after an embedded WebView resume.
 * The iOS shell reloads a terminated content process; this keeps the PWA
 * layout and app-state consumers synchronized after the document is restored.
 */
const PWA_RESUMED_EVENT = 'beamio:pwa-resumed'

export function installPwaLifecycleRecovery(): () => void {
	let frame: number | undefined

	const notifyResume = () => {
		if (frame != null) cancelAnimationFrame(frame)
		frame = requestAnimationFrame(() => {
			frame = undefined
			const root = document.documentElement
			const prevTransform = root.style.transform
			root.style.transform = 'translateZ(0)'
			void root.offsetHeight
			root.style.transform = prevTransform
			window.dispatchEvent(new CustomEvent(PWA_RESUMED_EVENT))
			window.dispatchEvent(new Event('resize'))
		})
	}

	const onVisibilityChange = () => {
		if (document.visibilityState === 'visible') notifyResume()
	}
	const onPageShow = () => notifyResume()

	document.addEventListener('visibilitychange', onVisibilityChange)
	window.addEventListener('pageshow', onPageShow)
	notifyResume()

	return () => {
		document.removeEventListener('visibilitychange', onVisibilityChange)
		window.removeEventListener('pageshow', onPageShow)
		if (frame != null) cancelAnimationFrame(frame)
	}
}
