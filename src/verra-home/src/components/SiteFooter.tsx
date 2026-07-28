import { Link } from 'react-router-dom'
import { BrandLogo } from './BrandLogo'

type SiteFooterProps = {
	/** Extra classes on the outer `<footer>` (e.g. `mt-12` if a page needs less top gap). */
	className?: string
}

export function SiteFooter({ className = '' }: SiteFooterProps) {
	return (
		<footer
			className={`mt-20 flex w-full flex-col gap-12 rounded-t-[40px] bg-slate-950 px-12 py-16 font-['Inter'] text-sm tracking-wide text-white ${className}`.trim()}
		>
			<div className="flex w-full flex-col items-start justify-between md:flex-row md:items-center">
				<div className="flex flex-col gap-4">
					<BrandLogo
						wordmark="VERRA"
						wordmarkClassName="text-xl font-bold text-white"
						imgClassName="h-8 w-8 shrink-0 object-contain"
						logoOnDark
					/>
					<p className="text-slate-400">© 2026 VERRA. All rights reserved.</p>
				</div>
				<div className="mt-8 flex flex-col items-end gap-8 md:mt-0">
					<div className="flex gap-8 text-slate-400">
						<Link className="transition-colors hover:text-white" to="/privacy">
							Privacy
						</Link>
						<Link className="transition-colors hover:text-white" to="/terms">
							Terms
						</Link>
						<Link className="transition-colors hover:text-white" to="/contact">
							Contact
						</Link>
					</div>
					<div className="flex gap-6 text-slate-400">
						<button type="button" className="transition-colors hover:text-white" aria-label="Web">
							<span className="material-symbols-outlined">public</span>
						</button>
						<Link className="transition-colors hover:text-white" to="/wallet" aria-label="Wallet">
							<span className="material-symbols-outlined">account_balance_wallet</span>
						</Link>
						<button type="button" className="transition-colors hover:text-white" aria-label="Share">
							<span className="material-symbols-outlined">share</span>
						</button>
						<button type="button" className="transition-colors hover:text-white" aria-label="Verified">
							<span className="material-symbols-outlined">verified_user</span>
						</button>
					</div>
				</div>
			</div>
		</footer>
	)
}
