import { createRoot } from 'react-dom/client'
import { RootErrorBoundary } from './components/RootErrorBoundary'
import './index.css'
import App from './App.tsx'

const rootEl = document.getElementById('root')
if (!rootEl) {
	document.body.innerHTML =
		'<p style="padding:16px;font-family:system-ui">Missing #root. Check index.html.</p>'
} else {
	try {
		createRoot(rootEl).render(
			<RootErrorBoundary>
				<App />
			</RootErrorBoundary>,
		)
	} catch (e) {
		const msg = e instanceof Error ? e.message : String(e)
		rootEl.innerHTML = `<div style="padding:16px;font-family:system-ui;background:#f9f9fe;color:#1a1c1f"><p style="font-weight:700">Failed to start</p><pre style="white-space:pre-wrap;font-size:12px;margin-top:8px">${msg}</pre></div>`
		console.error('[verra-home] createRoot failed', e)
	}
}
