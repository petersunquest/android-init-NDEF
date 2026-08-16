import { createRoot } from 'react-dom/client'
import App from './App'
import { lockPosAppColorScheme } from './boot/lockPosAppColorScheme'
import { unregisterPosServiceWorkers } from './utils/unregisterPosServiceWorkers'
import './index.css'

lockPosAppColorScheme()

void (async () => {
	// Await clear so leftover SW cannot race the first navigation / fetch.
	await unregisterPosServiceWorkers()

	const rootEl = document.getElementById('root')
	if (!rootEl) {
		document.body.innerHTML =
			'<p style="padding:16px;font-family:system-ui">Missing #root</p>'
		return
	}
	createRoot(rootEl).render(<App />)
})()
