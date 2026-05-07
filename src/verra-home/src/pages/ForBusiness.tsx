import { Link } from 'react-router-dom'
import { SiteFooter } from '../components/SiteFooter'
import { SiteHeader } from '../components/SiteHeader'

const HERO_IMAGE =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuBOek7QsD-9bKEJPiBnGAU0uMr7gwrlUVOFdH0kpm9T4-zJJsUzXMlLudjn22wsqXZGucyVtGGF5x9nCuEga-7dAF6SCebGjLIr4R5Tdo5-uH9JAaEZYozZzTAKWVIYeili7ghKfaq77dWg0Bjcs6STybUv_HB_1cl6Qc5IzuY-irPs2uPehnIFuM3TtP1X7nUnph5UibVb0o0G5aVP6Y5E47LJjQYCx4FdmzEDm8Szfseh1oajwf3YUF7N-k92teCrmxggIWQaDKhU'

export function ForBusiness() {
	return (
		<div className="min-h-dvh bg-background font-body text-on-surface selection:bg-primary-container selection:text-on-primary-container antialiased">
			<SiteHeader />

			<section className="relative flex min-h-[795px] items-center overflow-hidden pt-20">
				<div className="absolute inset-0 z-0">
					<img
						alt="Warm sunlit interior of a local independent coffee shop"
						className="h-full w-full object-cover blur-sm"
						src={HERO_IMAGE}
					/>
					<div className="hero-overlay absolute inset-0" />
				</div>
				<div className="relative z-10 mx-auto grid w-full max-w-7xl grid-cols-1 gap-12 px-8 lg:grid-cols-12">
					<div className="flex flex-col justify-center lg:col-span-8">
						<span className="mb-6 inline-block rounded-full bg-primary-fixed px-4 py-1.5 text-sm font-bold uppercase tracking-widest text-on-primary-fixed">
							The Margin Revolution
						</span>
						<h1 className="mb-8 text-5xl font-black leading-[0.95] tracking-tighter text-on-surface md:text-7xl lg:text-8xl">
							Stop paying a tax <br />
							<span className="text-primary">on your success.</span>
						</h1>
						<p className="mb-12 max-w-2xl text-xl leading-relaxed text-on-surface-variant md:text-2xl">
							Traditional credit cards punish you for selling more. Verra is a closed-loop economic engine that
							gives you your margins—and your customers—back.
						</p>
						<div className="flex flex-col gap-4 sm:flex-row">
							<button
								type="button"
								className="rounded-full bg-primary px-10 py-5 text-lg font-bold text-white shadow-xl transition-transform hover:scale-105"
								onClick={() =>
									document
										.getElementById('business-value-panels')
										?.scrollIntoView({ behavior: 'smooth', block: 'start' })
								}
							>
								Start keeping your value
							</button>
							<button
								type="button"
								className="rounded-full border-2 border-outline-variant px-10 py-5 text-lg font-bold text-on-surface transition-colors hover:bg-surface-container-low"
								onClick={() =>
									document
										.getElementById('business-phone-terminal')
										?.scrollIntoView({ behavior: 'smooth', block: 'start' })
								}
							>
								See how it works
							</button>
						</div>
					</div>
				</div>
			</section>

			<section
				id="business-value-panels"
				className="scroll-mt-24 bg-surface-container-low py-32 md:scroll-mt-28"
			>
				<div className="mx-auto max-w-7xl px-8">
					<div className="grid grid-cols-1 gap-8 md:grid-cols-2">
						<div className="group flex flex-col items-start gap-6 rounded-lg bg-surface-container-lowest p-12 transition-all duration-500 hover:bg-surface-bright">
							<div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-primary-container text-on-primary-container">
								<span className="material-symbols-outlined text-3xl">account_balance_wallet</span>
							</div>
							<h3 className="text-3xl font-bold tracking-tight">Upfront Cash Flow</h3>
							<p className="text-lg leading-relaxed text-on-surface-variant">
								Access your revenue instantly. We bridge the gap between service delivery and settlement,
								ensuring your operations never lose momentum.
							</p>
						</div>
						<div className="group flex flex-col items-start gap-6 rounded-lg bg-surface-container-lowest p-12 transition-all duration-500 hover:bg-surface-bright">
							<div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-primary-container text-on-primary-container">
								<span className="material-symbols-outlined text-3xl">local_gas_station</span>
							</div>
							<h3 className="text-3xl font-bold tracking-tight">Flat-rate Fuel</h3>
							<p className="text-lg leading-relaxed text-on-surface-variant">
								No percentage-based scaling. Predictable, flat rates that stay the same whether you process a
								hundred dollars or a hundred thousand.
							</p>
						</div>
						<div className="group flex flex-col items-start gap-6 rounded-lg bg-surface-container-lowest p-12 transition-all duration-500 hover:bg-surface-bright">
							<div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-primary-container text-on-primary-container">
								<span className="material-symbols-outlined text-3xl">hub</span>
							</div>
							<h3 className="text-3xl font-bold tracking-tight">Direct Connection</h3>
							<p className="text-lg leading-relaxed text-on-surface-variant">
								Remove the middlemen. Verra connects your business directly to your community through our
								integrated peer-to-peer ecosystem.
							</p>
						</div>
						<div className="group flex flex-col items-start gap-6 rounded-lg bg-surface-container-lowest p-12 transition-all duration-500 hover:bg-surface-bright">
							<div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-primary-container text-on-primary-container">
								<span className="material-symbols-outlined text-3xl">touch_app</span>
							</div>
							<h3 className="text-3xl font-bold tracking-tight">Zero Hardware</h3>
							<p className="text-lg leading-relaxed text-on-surface-variant">
								Ditch the bulky terminals and proprietary cables. Accept any payment method using the device
								you already carry in your pocket.
							</p>
						</div>
					</div>
				</div>
			</section>

			<section
				id="business-phone-terminal"
				className="scroll-mt-24 overflow-hidden py-32 md:scroll-mt-28"
			>
				<div className="mx-auto grid max-w-7xl grid-cols-1 items-center gap-20 px-8 lg:grid-cols-2">
					<div className="order-2 lg:order-1">
						<h2 className="mb-8 text-5xl font-black leading-tight tracking-tighter">
							Your phone is <br />
							the terminal.
						</h2>
						<p className="mb-12 text-xl leading-relaxed text-on-surface-variant">
							Verra SoftPOS turns any modern smartphone into a high-security payment hub. Accept NFC card taps,
							QR scans, and peer-to-peer transfers with zero additional hardware required.
						</p>
						<div className="flex flex-wrap gap-4">
							<a
								href="https://testflight.apple.com/join/ytm1F8Aq"
								target="_blank"
								rel="noopener noreferrer"
								className="group flex items-center gap-3 rounded-full bg-surface-container-high px-8 py-4 font-bold transition-all hover:bg-surface-container-highest"
							>
								<span className="material-symbols-outlined">developer_mode</span>
								Apple TestFlight
							</a>
							<a
								href="https://github.com/petersunquest/android-NDEF/releases/download/v1.0.1/app-release.apk"
								target="_blank"
								rel="noopener noreferrer"
								className="group flex items-center gap-3 rounded-full bg-surface-container-high px-8 py-4 font-bold transition-all hover:bg-surface-container-highest"
							>
								<span className="material-symbols-outlined">android</span>
								Android APK
							</a>
						</div>
					</div>
					<div className="order-1 flex justify-center lg:order-2 lg:justify-end">
						<div className="relative h-[640px] w-[320px] rounded-[3rem] bg-slate-900 p-3 shadow-2xl outline outline-[12px] outline-slate-800">
							<div className="flex h-full w-full flex-col overflow-hidden rounded-[2.5rem] bg-white">
								<div className="flex h-10 items-center justify-between px-8 pt-4">
									<span className="text-xs font-bold">9:41</span>
									<div className="h-6 w-20 rounded-full bg-black" />
									<div className="flex gap-1">
										<span className="material-symbols-outlined text-[12px]">signal_cellular_alt</span>
										<span className="material-symbols-outlined text-[12px]">wifi</span>
									</div>
								</div>
								<div className="flex flex-grow flex-col items-center justify-center p-8 text-center">
									<div className="mb-8 flex h-24 w-24 items-center justify-center rounded-3xl bg-primary shadow-lg">
										<span className="material-symbols-outlined text-5xl text-white">contactless</span>
									</div>
									<h4 className="mb-2 text-2xl font-bold">Ready to Tap</h4>
									<p className="mb-12 text-sm text-on-surface-variant">
										Hold card or phone near the back of this device
									</p>
									<div className="mono-fig mb-2 text-4xl font-black">$42.00</div>
									<div className="font-medium text-on-surface-variant">Grand Cafe Verra</div>
								</div>
								<div className="bg-surface-container-low p-8">
									<div className="mb-4 h-1 w-full rounded-full bg-surface-container-high" />
									<div className="flex items-center justify-between opacity-50">
										<span className="material-symbols-outlined">home</span>
										<span className="material-symbols-outlined">history</span>
										<span className="material-symbols-outlined">settings</span>
									</div>
								</div>
							</div>
						</div>
					</div>
				</div>
			</section>

			<section className="bg-surface-container-low py-32">
				<div className="mx-auto max-w-7xl px-8">
					<div className="mb-20 text-center">
						<h2 className="mb-4 text-5xl font-black tracking-tighter">Pure Infrastructure Performance.</h2>
						<p className="mx-auto max-w-3xl text-xl text-on-surface-variant">
							Verra charges a simple Technical Interaction Fee for the use of our decentralized routing
							infrastructure. No percentage taxes on your growth.
						</p>
					</div>
					<div className="grid grid-cols-1 gap-8 md:grid-cols-3">
						<div className="flex h-full flex-col rounded-lg bg-surface-container-lowest p-12 shadow-sm">
							<div className="mb-6 text-sm font-bold uppercase tracking-widest text-on-surface-variant">
								Network Interaction
							</div>
							<p className="mb-12 leading-relaxed text-on-surface-variant">
								Technical fee for every secure data interaction via the SoftPOS.
							</p>
							<div className="mt-auto">
								<div className="mono-fig text-4xl font-black text-primary">2 B-Units / interaction</div>
							</div>
						</div>
						<div className="flex h-full flex-col rounded-lg bg-surface-container-lowest p-12 shadow-sm">
							<div className="mb-6 text-sm font-bold uppercase tracking-widest text-on-surface-variant">
								Inbound Data Routing
							</div>
							<p className="mb-12 leading-relaxed text-on-surface-variant">
								System usage fee for routing initial digital value into your autonomous ledger.
							</p>
							<div className="mt-auto">
								<div className="mono-fig text-4xl font-black text-primary">2% of routed value</div>
							</div>
						</div>
						<div className="flex h-full flex-col rounded-lg border-2 border-primary-container bg-surface-container-lowest p-12 shadow-sm">
							<div className="mb-6 text-sm font-bold uppercase tracking-widest text-on-surface-variant">
								Standard Activation Kit
							</div>
							<p className="mb-12 leading-relaxed text-on-surface-variant">
								C$69 one-time infrastructure setup. Includes 10 physical NFC nodes and 2,000 bonus B-Units.
							</p>
							<div className="mt-auto">
								<div className="mono-fig text-4xl font-black text-primary">C$69</div>
							</div>
						</div>
					</div>
				</div>
			</section>

			<section className="py-32">
				<div className="mx-auto max-w-7xl px-8">
					<div className="mb-16">
						<h2 className="mb-6 text-5xl font-black tracking-tighter">Verra Business OS</h2>
						<p className="max-w-2xl text-xl text-on-surface-variant">
							A desktop-class dashboard designed for clarity. Monitor settlements, manage loyalty nodes, and watch
							your local ecosystem grow in real-time.
						</p>
						<a
							href="https://biz.beamio.app/biz/"
							target="_blank"
							rel="noopener noreferrer"
							className="mt-8 inline-flex items-center justify-center rounded-full bg-primary px-10 py-5 text-lg font-bold text-white shadow-xl transition-transform hover:scale-105"
						>
							Open Business Dashboard
						</a>
					</div>
					<div className="overflow-hidden rounded-xl bg-surface-container-high p-1 shadow-2xl">
						<div className="flex h-10 items-center gap-2 bg-surface-container-highest px-6">
							<div className="h-3 w-3 rounded-full bg-error/40" />
							<div className="h-3 w-3 rounded-full bg-secondary-container" />
							<div className="h-3 w-3 rounded-full bg-primary-fixed-dim" />
							<div className="mx-auto flex h-6 w-1/3 items-center rounded-md bg-surface-container-lowest px-4">
								<span className="text-[10px] text-on-surface-variant opacity-50">
									business.verra.engine/dashboard
								</span>
							</div>
						</div>
						<div className="grid min-h-[500px] grid-cols-12 gap-8 bg-surface-container-lowest p-8">
							<div className="col-span-3 space-y-6">
								<div className="h-8 w-3/4 rounded-lg bg-surface-container-low" />
								<div className="space-y-3">
									<div className="h-10 rounded-lg border-l-4 border-primary bg-primary/10" />
									<div className="h-10 rounded-lg bg-surface-container-low" />
									<div className="h-10 rounded-lg bg-surface-container-low" />
									<div className="h-10 rounded-lg bg-surface-container-low" />
								</div>
							</div>
							<div className="col-span-9 space-y-8">
								<div className="grid grid-cols-3 gap-6">
									<div className="h-32 rounded-lg bg-surface-container-low p-6">
										<div className="mb-4 h-3 w-1/3 rounded bg-on-surface-variant/20" />
										<div className="h-8 w-2/3 rounded bg-primary/40" />
									</div>
									<div className="h-32 rounded-lg bg-surface-container-low p-6">
										<div className="mb-4 h-3 w-1/3 rounded bg-on-surface-variant/20" />
										<div className="h-8 w-2/3 rounded bg-secondary/40" />
									</div>
									<div className="h-32 rounded-lg bg-surface-container-low p-6">
										<div className="mb-4 h-3 w-1/3 rounded bg-on-surface-variant/20" />
										<div className="h-8 w-2/3 rounded bg-tertiary-container/20" />
									</div>
								</div>
								<div className="relative h-64 overflow-hidden rounded-lg bg-surface-container-low">
									<svg
										className="absolute bottom-0 h-40 w-full"
										preserveAspectRatio="none"
										viewBox="0 0 900 100"
										aria-hidden
									>
										<path
											d="M0 100 Q 150 20, 300 80 T 600 40 T 900 60"
											fill="none"
											stroke="#004bc3"
											strokeWidth="4"
										/>
									</svg>
								</div>
							</div>
						</div>
					</div>
				</div>
			</section>

			<section className="px-8 pb-32">
				<div className="group relative mx-auto max-w-7xl overflow-hidden rounded-lg bg-primary p-16 text-center text-white md:p-24">
					<div className="absolute inset-0 bg-[radial-gradient(circle_at_center,_var(--tw-gradient-stops))] from-white via-transparent to-transparent opacity-10" />
					<h2 className="relative z-10 mb-12 text-4xl font-black tracking-tighter md:text-6xl">
						Ready to reclaim your margins <br />
						and your customers?
					</h2>
					<Link
						to="/contact"
						className="relative z-10 inline-block rounded-full bg-white px-12 py-6 text-xl font-black text-primary shadow-2xl transition-transform hover:scale-105"
					>
						Get Started Now
					</Link>
				</div>
			</section>

			<SiteFooter />
		</div>
	)
}
