import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
	plugins: [react()],
	build: {
		// Slightly wider runtime support for older in-app WebViews (e.g. some wallet browsers).
		target: ['es2020', 'edge88', 'firefox78', 'chrome87', 'safari14'],
	},
})
