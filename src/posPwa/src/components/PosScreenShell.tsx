import type { ReactNode } from 'react'

/** POS PWA screen root — see `.cursor/rules/beamio-pos-pwa-fullscreen-layout.mdc` */
export function PosScreenShell({
	children,
	className = '',
	bg = 'bg-white',
}: {
	children: ReactNode
	className?: string
	bg?: string
}) {
	return (
		<div
			className={`flex h-dvh max-h-dvh w-full max-w-[100vw] flex-col overflow-hidden overscroll-none text-mkt-onSurface ${bg} ${className}`.trim()}
		>
			{children}
		</div>
	)
}

export function PosScreenHeader({
	children,
	className = '',
}: {
	children: ReactNode
	className?: string
}) {
	return (
		<header
			className={`shrink-0 pt-[max(0.75rem,env(safe-area-inset-top))] ${className}`.trim()}
		>
			{children}
		</header>
	)
}

export function PosScreenMain({
	children,
	className = '',
}: {
	children: ReactNode
	className?: string
}) {
	return (
		<main className={`flex min-h-0 flex-1 flex-col overflow-hidden ${className}`.trim()}>
			{children}
		</main>
	)
}

export function PosScreenFooter({
	children,
	className = '',
}: {
	children: ReactNode
	className?: string
}) {
	return (
		<footer
			className={`shrink-0 border-t border-slate-200/80 bg-white/95 px-6 py-4 pb-[max(1rem,env(safe-area-inset-bottom))] backdrop-blur ${className}`.trim()}
		>
			{children}
		</footer>
	)
}
