import { useEffect, useState } from 'react'
import { Link, NavLink, useLocation } from 'react-router-dom'
import { BrandLogo } from './BrandLogo'

const navClass = ({ isActive }: { isActive: boolean }) =>
	isActive
		? "border-b-2 border-blue-600 font-['Inter'] font-semibold tracking-tight text-blue-600 dark:text-blue-400"
		: "font-['Inter'] font-medium tracking-tight text-slate-600 transition-opacity duration-300 hover:text-blue-500 dark:text-slate-400"

const mobileNavClass = ({ isActive }: { isActive: boolean }) =>
	isActive
		? "rounded-lg bg-primary-container/15 py-3 pl-4 font-['Inter'] font-semibold text-blue-600 dark:text-blue-400"
		: "rounded-lg py-3 pl-4 font-['Inter'] font-medium text-slate-700 transition-colors hover:bg-slate-100 dark:text-slate-200 dark:hover:bg-slate-800"

const logoProps = {
	className: 'flex items-center gap-0',
	imgClassName: 'h-8 w-8 shrink-0 object-contain md:h-9 md:w-9',
	wordmarkClassName: 'text-2xl font-bold tracking-tight text-blue-600 dark:text-blue-500',
} as const

export function SiteHeader() {
	const [mobileMenuOpen, setMobileMenuOpen] = useState(false)
	const location = useLocation()

	useEffect(() => {
		setMobileMenuOpen(false)
	}, [location.pathname])

	useEffect(() => {
		if (!mobileMenuOpen) return
		const previous = document.body.style.overflow
		document.body.style.overflow = 'hidden'
		return () => {
			document.body.style.overflow = previous
		}
	}, [mobileMenuOpen])

	useEffect(() => {
		if (!mobileMenuOpen) return
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape') setMobileMenuOpen(false)
		}
		window.addEventListener('keydown', onKey)
		return () => window.removeEventListener('keydown', onKey)
	}, [mobileMenuOpen])

	return (
		<>
			{mobileMenuOpen ? (
				<div
					className="fixed inset-0 z-40 bg-black/40 backdrop-blur-[2px] md:hidden"
					aria-hidden
					onClick={() => setMobileMenuOpen(false)}
				/>
			) : null}
			<header className="fixed top-0 left-0 right-0 z-50 w-full bg-white/80 shadow-sm backdrop-blur-xl dark:bg-slate-900/80 dark:shadow-none">
				<div className="mx-auto flex max-w-7xl items-center justify-between gap-4 px-8 py-4">
					<div className="min-w-0 shrink">
						<button
							type="button"
							className="rounded-md md:hidden"
							onClick={() => setMobileMenuOpen((open) => !open)}
							aria-expanded={mobileMenuOpen}
							aria-controls="site-header-mobile-nav"
							aria-label={mobileMenuOpen ? 'Close navigation menu' : 'Open navigation menu'}
						>
							<BrandLogo to={null} {...logoProps} />
						</button>
						<div className="hidden md:block">
							<BrandLogo {...logoProps} />
						</div>
					</div>
					<nav className="hidden items-center gap-10 md:flex" aria-label="Main">
						<NavLink to="/" end className={navClass}>
							Home
						</NavLink>
						<NavLink to="/local" className={navClass}>
							The Local
						</NavLink>
						<NavLink to="/business" className={navClass}>
							The Business
						</NavLink>
						<NavLink to="/impact" className={navClass}>
							Impact
						</NavLink>
					</nav>
					<Link
						to="/contact"
						className="shrink-0 rounded-full bg-primary-container px-6 py-2.5 text-center font-semibold text-on-primary-container transition-all hover:opacity-80 active:scale-95"
					>
						Get Started
					</Link>
				</div>

				{mobileMenuOpen ? (
					<div
						id="site-header-mobile-nav"
						className="max-h-[calc(100dvh-5.5rem)] overflow-y-auto border-t border-slate-200/80 bg-white/95 dark:border-slate-700/80 dark:bg-slate-900/95 md:hidden"
						role="dialog"
						aria-modal="true"
						aria-label="Site navigation"
					>
						<nav className="mx-auto flex max-w-7xl flex-col gap-1 px-8 py-4 pb-6" aria-label="Mobile main">
							<NavLink to="/" end className={mobileNavClass} onClick={() => setMobileMenuOpen(false)}>
								Home
							</NavLink>
							<NavLink to="/local" className={mobileNavClass} onClick={() => setMobileMenuOpen(false)}>
								The Local
							</NavLink>
							<NavLink to="/business" className={mobileNavClass} onClick={() => setMobileMenuOpen(false)}>
								The Business
							</NavLink>
							<NavLink to="/impact" className={mobileNavClass} onClick={() => setMobileMenuOpen(false)}>
								Impact
							</NavLink>
						</nav>
					</div>
				) : null}
			</header>
		</>
	)
}
