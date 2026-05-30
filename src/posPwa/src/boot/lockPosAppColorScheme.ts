/** POS PWA always uses designed light UI — never follow OS / WebView dark mode. */
export function lockPosAppColorScheme(): void {
	const html = document.documentElement

	const apply = (): void => {
		html.classList.remove('dark')
		html.classList.add('light')
		html.style.setProperty('color-scheme', 'light only')
		html.dataset.posTheme = 'light'
	}

	apply()

	window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', apply)
	window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', apply)
}
