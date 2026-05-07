import { Link } from 'react-router-dom'
import { SiteFooter } from '../components/SiteFooter'
import { SiteHeader } from '../components/SiteHeader'

const HERO_IMAGE =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuDjtUecXEZL8bYsb_HwRNDDqOJmW0XisFMhMrVZJGqqdrnmVQyCZAKcFcoMO7NFv35zaehrtynKkrbLAlmyivO1bIcgvq-yJJ2DiWNVOiKsEQa_LzHY2ttAy2Bm57lTlNxlLBte2PNGjN4euGAGzcGqMWKJ4nDsodQw5UW2kEz43kOZhAh_eJIPXpGWl9LfHQURXh99gB-CMEsCgJQU55WTBelprv66qPoZQ2mBG9Sg7Ou7RnsB8FRCOVMTp7QpfDyrq65SxA0mm8zE'

const iconFilled = {
	fontVariationSettings: "'FILL' 1, 'wght' 400, 'GRAD' 0, 'opsz' 24" as const,
}

export function Home() {
	return (
		<div className="min-h-dvh bg-background text-on-surface antialiased">
			<SiteHeader />

			<main className="pt-20">
				<section className="relative flex h-[751px] items-center justify-center overflow-hidden">
					<div className="absolute inset-0 z-0">
						<img
							className="h-full w-full object-cover brightness-[0.4] contrast-125"
							alt="Atmospheric city streetscape at dusk with golden bokeh lights"
							src={HERO_IMAGE}
						/>
						<div className="absolute inset-0 bg-gradient-to-b from-transparent via-slate-950/20 to-slate-950/60" />
					</div>
					<div className="relative z-10 mx-auto max-w-4xl px-6 text-center">
						<h1 className="mb-6 text-5xl font-extrabold tracking-tight text-white md:text-7xl">
							One network.
							<br />
							Three ways to win.
						</h1>
						<p className="mx-auto mb-10 max-w-2xl text-lg font-light leading-relaxed text-slate-300 md:text-xl">
							A decentralized, closed-loop economic engine built for the people and places you trust.
						</p>
						<div className="flex flex-col items-center justify-center gap-4 sm:flex-row">
							<button
								type="button"
								className="primary-gradient rounded-full px-10 py-4 text-lg font-bold text-white shadow-xl transition-transform hover:scale-105 active:scale-95"
								onClick={() =>
									document
										.getElementById('feature-panels')
										?.scrollIntoView({ behavior: 'smooth', block: 'start' })
								}
							>
								Explore Here
							</button>
							<button
								type="button"
								className="rounded-full border border-white/20 bg-white/10 px-10 py-4 text-lg font-bold text-white backdrop-blur-md transition-all hover:bg-white hover:text-blue-900 active:scale-95"
								onClick={() =>
									document
										.getElementById('built-for-main-street')
										?.scrollIntoView({ behavior: 'smooth', block: 'start' })
								}
							>
								How it works
							</button>
						</div>
					</div>
				</section>

				<section
					id="feature-panels"
					className="relative z-20 -mt-32 scroll-mt-24 mx-auto max-w-7xl px-8 pb-20 md:scroll-mt-28"
				>
					<div className="grid grid-cols-1 gap-8 md:grid-cols-3">
						<div className="group rounded-lg border border-outline-variant/10 bg-surface-container-lowest p-10 shadow-[0_4px_24px_rgba(0,0,0,0.04)] transition-all duration-500 hover:shadow-[0_8px_32px_rgba(0,0,0,0.08)]">
							<div className="mb-8 flex h-16 w-16 items-center justify-center rounded-2xl bg-primary-container/10 transition-transform group-hover:scale-110">
								<span
									className="material-symbols-outlined text-4xl text-blue-600"
									style={iconFilled}
								>
									wallet
								</span>
							</div>
							<h3 className="mb-4 text-2xl font-bold text-on-surface">Your digital vault.</h3>
							<p className="mb-8 h-20 leading-relaxed text-on-surface-variant">
								Ditch the plastic. Manage your digital stored-value and tap-to-pay seamlessly.
							</p>
							<Link
								className="flex items-center gap-2 font-bold text-blue-600 transition-all group-hover:gap-4"
								to="/local"
							>
								Learn more <span className="material-symbols-outlined">arrow_forward</span>
							</Link>
						</div>

						<div className="group rounded-lg border border-outline-variant/10 bg-surface-container-lowest p-10 shadow-[0_4px_24px_rgba(0,0,0,0.04)] transition-all duration-500 hover:shadow-[0_8px_32px_rgba(0,0,0,0.08)]">
							<div className="mb-8 flex h-16 w-16 items-center justify-center rounded-2xl bg-primary-container/10 transition-transform group-hover:scale-110">
								<span
									className="material-symbols-outlined text-4xl text-blue-600"
									style={iconFilled}
								>
									storefront
								</span>
							</div>
							<h3 className="mb-4 text-2xl font-bold text-on-surface">Zero monthly rent.</h3>
							<p className="mb-8 h-20 leading-relaxed text-on-surface-variant">
								Scalable non-custodial commerce. 2% Inbound Routing Fee + flat Technical Interaction
								Fee.
							</p>
							<Link
								className="flex items-center gap-2 font-bold text-blue-600 transition-all group-hover:gap-4"
								to="/business"
							>
								Learn more <span className="material-symbols-outlined">arrow_forward</span>
							</Link>
						</div>

						<div className="group rounded-lg border border-outline-variant/10 bg-surface-container-lowest p-10 shadow-[0_4px_24px_rgba(0,0,0,0.04)] transition-all duration-500 hover:shadow-[0_8px_32px_rgba(0,0,0,0.08)]">
							<div className="mb-8 flex h-16 w-16 items-center justify-center rounded-2xl bg-primary-container/10 transition-transform group-hover:scale-110">
								<span
									className="material-symbols-outlined text-4xl text-blue-600"
									style={iconFilled}
								>
									favorite
								</span>
							</div>
							<h3 className="mb-4 text-2xl font-bold text-on-surface">Zero-fee philanthropy.</h3>
							<p className="mb-8 h-20 leading-relaxed text-on-surface-variant">
								Direct-to-cause giving. Every cent reaches the intended hands.
							</p>
							<Link
								className="flex items-center gap-2 font-bold text-blue-600 transition-all group-hover:gap-4"
								to="/impact"
							>
								Learn more <span className="material-symbols-outlined">arrow_forward</span>
							</Link>
						</div>
					</div>
				</section>

				<section
					id="built-for-main-street"
					className="scroll-mt-24 overflow-hidden bg-surface-container-low px-8 py-32 md:scroll-mt-28"
				>
					<div className="mx-auto grid max-w-7xl grid-cols-1 items-center gap-20 lg:grid-cols-2">
						<div className="space-y-6">
							<span className="block text-sm font-bold uppercase tracking-[0.2em] text-blue-600">
								THE VERRA PROMISE
							</span>
							<h2 className="text-4xl font-extrabold leading-tight tracking-tight text-on-surface md:text-5xl">
								Built for Main Street,
								<br />
								not Wall Street.
							</h2>
							<p className="max-w-lg text-xl font-light text-on-surface-variant">
								No hidden fees, no hardware rentals, pure community connection.
							</p>
						</div>
						<div className="flex flex-col gap-6">
							<div className="group flex items-center gap-6 rounded-lg bg-surface-container-lowest p-8 transition-colors duration-300 hover:bg-white">
								<div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-full bg-blue-50 text-blue-600">
									<span className="material-symbols-outlined text-3xl">bolt</span>
								</div>
								<div>
									<h4 className="text-xl font-bold text-on-surface">Instant Settlement</h4>
									<p className="text-on-surface-variant">Value moves at the speed of thought.</p>
								</div>
							</div>
							<div className="group flex items-center gap-6 rounded-lg bg-surface-container-lowest p-8 transition-colors duration-300 hover:bg-white">
								<div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-full bg-blue-50 text-blue-600">
									<span className="material-symbols-outlined text-3xl">devices_off</span>
								</div>
								<div>
									<h4 className="text-xl font-bold text-on-surface">Zero Hardware</h4>
									<p className="text-on-surface-variant">No readers, no rentals, just your smartphone.</p>
								</div>
							</div>
							<div className="group flex items-center gap-6 rounded-lg bg-surface-container-lowest p-8 transition-colors duration-300 hover:bg-white">
								<div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-full bg-blue-50 text-blue-600">
									<span className="material-symbols-outlined text-3xl">verified_user</span>
								</div>
								<div>
									<h4 className="text-xl font-bold text-on-surface">100% Transparent</h4>
									<p className="text-on-surface-variant">Built on trust and verifiable openness.</p>
								</div>
							</div>
						</div>
					</div>
				</section>

				<section id="open-beta" className="scroll-mt-24 bg-white px-8 py-32 md:scroll-mt-28">
					<div className="mx-auto max-w-7xl">
						<h2 className="mb-20 text-center text-4xl font-extrabold tracking-tight text-on-surface md:text-5xl">
							Access the Open Beta
						</h2>
						<div className="grid grid-cols-1 gap-8 md:grid-cols-2">
							<div className="flex flex-col items-start rounded-3xl border border-slate-100 bg-white p-10 shadow-[0_8px_30px_rgb(0,0,0,0.04)] transition-transform hover:-translate-y-1 md:p-12">
								<span className="mb-6 text-sm font-bold uppercase tracking-[0.2em] text-[#1562F0]">
									THE LOCAL
								</span>
								<h3 className="mb-4 text-3xl font-extrabold text-on-surface">Consumer Digital Vault</h3>
								<p className="mb-10 text-lg leading-relaxed text-on-surface-variant">
									Your personal AA smart wallet for local commerce. Download the app or access instantly via browser.
								</p>
								<div className="mt-auto flex flex-wrap gap-3">
									<button
										type="button"
										className="rounded-full bg-[#f3f4f6] px-6 py-3 text-sm font-bold text-on-surface transition-colors hover:bg-slate-200 active:scale-95"
									>
										iOS TestFlight
									</button>
									<a
										href="https://play.google.com/store/apps/details?id=com.beamio.caehtrees"
										target="_blank"
										rel="noopener noreferrer"
										className="inline-flex rounded-full bg-[#f3f4f6] px-6 py-3 text-sm font-bold text-on-surface transition-colors hover:bg-slate-200 active:scale-95"
									>
										Android .APK
									</a>
									<button
										type="button"
										className="rounded-full bg-[#f3f4f6] px-6 py-3 text-sm font-bold text-on-surface transition-colors hover:bg-slate-200 active:scale-95"
									>
										Launch Web App
									</button>
								</div>
							</div>
							<div className="flex flex-col items-start rounded-3xl border border-slate-100 bg-white p-10 shadow-[0_8px_30px_rgb(0,0,0,0.04)] transition-transform hover:-translate-y-1 md:p-12">
								<span className="mb-6 text-sm font-bold uppercase tracking-[0.2em] text-[#1562F0]">
									THE BUSINESS
								</span>
								<h3 className="mb-4 text-3xl font-extrabold text-on-surface">SoftPOS & Business OS</h3>
								<p className="mb-10 text-lg leading-relaxed text-on-surface-variant">
									Turn your smartphone into a non-custodial terminal, or manage your closed-loop empire directly from
									your desktop browser.
								</p>
								<div className="mt-auto flex flex-wrap gap-3">
									<button
										type="button"
										className="rounded-full bg-[#f3f4f6] px-6 py-3 text-sm font-bold text-on-surface transition-colors hover:bg-slate-200 active:scale-95"
									>
										iOS TestFlight
									</button>
									<a
										href="https://play.google.com/store/apps/details?id=com.beamio.caehtrees"
										target="_blank"
										rel="noopener noreferrer"
										className="inline-flex rounded-full bg-[#f3f4f6] px-6 py-3 text-sm font-bold text-on-surface transition-colors hover:bg-slate-200 active:scale-95"
									>
										Android .APK
									</a>
									<button
										type="button"
										className="rounded-full bg-[#f3f4f6] px-6 py-3 text-sm font-bold text-on-surface transition-colors hover:bg-slate-200 active:scale-95"
									>
										Launch Web OS
									</button>
								</div>
							</div>
						</div>
					</div>
				</section>

				<section className="mx-auto max-w-7xl px-8 py-24">
					<div className="primary-gradient group relative overflow-hidden rounded-xl p-12 text-center md:p-24">
						<div className="absolute inset-0 bg-[radial-gradient(circle_at_center,_var(--tw-gradient-stops))] from-white via-transparent to-transparent opacity-10" />
						<div className="relative z-10">
							<h2 className="mb-6 text-4xl font-extrabold tracking-tight text-white md:text-6xl">
								Ready to reclaim your value?
							</h2>
							<p className="mx-auto mb-12 max-w-2xl text-xl text-white/80">
								Join thousands of others building a more equitable economic future today.
							</p>
							<Link
								to="/contact"
								className="inline-block rounded-full bg-white px-12 py-5 text-xl font-bold text-blue-700 shadow-2xl transition-colors hover:bg-blue-50 active:scale-95"
							>
								Get Started Now
							</Link>
						</div>
					</div>
				</section>
			</main>

			<SiteFooter />
		</div>
	)
}
