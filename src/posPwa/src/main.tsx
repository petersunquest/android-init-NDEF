import { createRoot } from 'react-dom/client'
import App from './App'
import { lockPosAppColorScheme } from './boot/lockPosAppColorScheme'
import { unregisterPosServiceWorkers } from './utils/unregisterPosServiceWorkers'
import './index.css'

lockPosAppColorScheme()

void (async () => {
	/*
	 * Bounded wait: getRegistrations / caches.keys can hang on some WebViews. A hung cleanup
	 * must not block React mount (otherwise the page stays an empty dark surface).
	 */
	await Promise.race([
		unregisterPosServiceWorkers(),
		new Promise<void>((resolve) => window.setTimeout(resolve, 1500)),
	])

	const rootEl = document.getElementById('root')
	if (!rootEl) {
		document.body.innerHTML =
			'<p style="padding:16px;font-family:system-ui">Missing #root</p>'
		return
	}
	createRoot(rootEl).render(<App />)
})()
