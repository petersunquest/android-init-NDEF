import { createRoot } from 'react-dom/client'
import App from './App'
import './index.css'

const rootEl = document.getElementById('root')
if (!rootEl) {
	document.body.innerHTML =
		'<p style="padding:16px;font-family:system-ui">Missing #root</p>'
} else {
	createRoot(rootEl).render(<App />)
}
