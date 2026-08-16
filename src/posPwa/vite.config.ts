import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'node:path'

/** `/` for https://pos.conet.network ; default `/pos/` for https://beamio.app/pos/ */
const base = process.env.POS_PWA_BASE ?? '/pos/'

export default defineConfig({
	// Do **not** add vite-plugin-pwa / Workbox — POS updates are Embedded OTA only
	// (`update.json` + `BeamioPOS-*.zip`), not Service Worker autoUpdate.
	plugins: [react()],
	base,
	resolve: {
		alias: {
			'@': path.resolve(__dirname, './src'),
		},
	},
	build: {
		target: ['es2020', 'edge88', 'firefox78', 'chrome87', 'safari14'],
	},
})
