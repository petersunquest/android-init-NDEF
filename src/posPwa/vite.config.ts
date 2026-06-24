import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import path from 'node:path'

/** `/` for https://pos.conet.network ; default `/pos/` for https://beamio.app/pos/ */
const base = process.env.POS_PWA_BASE ?? '/pos/'

export default defineConfig({
	plugins: [
		react(),
		VitePWA({
			// 'prompt' = 静默后台下载新版，由 UI 显示「有更新」按钮，用户点击后才 skipWaiting + reload。
			registerType: 'prompt',
			// 用 useRegisterSW 手动注册（见 PosPwaUpdateGate），不向 index.html 注入注册脚本。
			injectRegister: false,
			// SPA navigateFallback 等需要正确 base 前缀（/pos/ 或 /）。
			scope: base,
			workbox: {
				// 预缓存全部 build 产物（含 hash 文件名），实现「本地缓存为主，打开即刻渲染」。
				globPatterns: ['**/*.{js,css,html,ico,png,svg,webp,woff,woff2,json}'],
				cleanupOutdatedCaches: true,
				clientsClaim: true,
				// SPA：任意路由（/home /charge …）离线/秒开都回退到预缓存的 index.html。
				navigateFallback: `${base}index.html`,
				// API、OG、metadata 等动态请求不走 SPA 回退，始终走网络。
				navigateFallbackDenylist: [/^\/api\//, /^\/og\//, /^\/metadata\//],
				// 单文件上限放宽（POS 含较大 vendor chunk）。
				maximumFileSizeToCacheInBytes: 6 * 1024 * 1024,
				runtimeCaching: [
					{
						// Google Fonts 样式表：网络优先，离线回退缓存。
						urlPattern: /^https:\/\/fonts\.googleapis\.com\/.*/i,
						handler: 'StaleWhileRevalidate',
						options: {
							cacheName: 'pos-google-fonts-stylesheets',
							expiration: { maxEntries: 8, maxAgeSeconds: 60 * 60 * 24 * 30 },
						},
					},
					{
						// 字体文件：缓存优先（一年）。
						urlPattern: /^https:\/\/fonts\.gstatic\.com\/.*/i,
						handler: 'CacheFirst',
						options: {
							cacheName: 'pos-google-fonts-webfonts',
							expiration: { maxEntries: 16, maxAgeSeconds: 60 * 60 * 24 * 365 },
							cacheableResponse: { statuses: [0, 200] },
						},
					},
				],
			},
			manifest: {
				name: 'Beamio POS',
				short_name: 'Beamio POS',
				description: 'Beamio merchant POS terminal',
				start_url: base,
				scope: base,
				display: 'standalone',
				orientation: 'portrait',
				background_color: '#000414',
				theme_color: '#000414',
				icons: [
					{
						src: `${base}cadd-icon.png`,
						sizes: '512x512',
						type: 'image/png',
						purpose: 'any maskable',
					},
				],
			},
			// 开发模式不启用 SW，避免缓存干扰热更新。
			devOptions: { enabled: false },
		}),
	],
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
