/** @type {import('tailwindcss').Config} */
export default {
	content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
	theme: {
		extend: {
			colors: {
				mkt: {
					bg: '#F5F7F9',
					primary: '#0051D1',
					onSurface: '#2C2F31',
					onSurfaceVariant: '#595C5E',
					surfaceLow: '#EEF1F3',
					outlineVariant: '#ABADAF',
				},
				brand: {
					blue: '#1562F0',
				},
			},
			fontFamily: {
				sans: ['Inter', 'ui-sans-serif', 'system-ui', 'sans-serif'],
			},
		},
	},
	plugins: [],
}
