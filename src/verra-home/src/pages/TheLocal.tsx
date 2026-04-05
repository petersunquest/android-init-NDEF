import { SiteFooter } from '../components/SiteFooter'
import { SiteHeader } from '../components/SiteHeader'

const IMG_VAULT_QR =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuAeRKuDtww1tP0FYfAKDyBFRsHM14cdJWhxPwzamDtx9ZCtyMwqxIvJiFUHuR7Pn1jmAlMrcQF5fOrj73SYHgz2luEa2dSycjGlb6jkTjMyc5ad9BVDAT99IE_oDQiIT2U9fUeb1V4J5qHn0_c1yyNKYoDzeHVetTJoIV4b0DciYUZtjOwu-WmKpXMIYLbtu_NkjpaxunSmN5EKirViFOxGPcBhQVvoPZXA7sXXBXJjypywIdzEj0QPL2OM5IISgBuB9_IQd18G4vAo'

const IMG_QR_SCAN =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuB6lNlb-RXbRpPlbYapoQ5XY1axHK4qIrm7XAb4l93_Nf6bGU46x2WQT2JRYL5vHyKTsLUb0q1MqxrrshW5S51gIJMgVmyCMuWcNe50Ap6g4OCW99Co4EvytB5dBrFTQh9tHYBbZQGSKf-lkVUbnnKkJOMnf8usVSIHxQnW0IGaMUBg8lqCpoSA9eIUG6EX2D-Tny4hXx9zxuhRGtTCkkkMrxxwJER1lYe0A_52TRgSJEOHu1mTA8wQDtAG1-02fW3VI6j5C58q1Ebg'

const IMG_NFC_WAVE =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuAIuigV8CKp85tdjctbPHhuAqFLUZz9muSc48wQmU3ozMDtHUTGUXFaz429cGli87jpWC1UYN4OVa7TDwPp-Yd8kunltXlzYmFbxx1rzs21pJx-0PQfKduAgNaHE3xQm4qespQ7Dftq0yIwm8Iqu0u53WjxnjzvLTs79tQE-qC6DPDT0RChvfwqoAELRYaR97bqywXL9qYWXZDMYdC0v68likgemq9E8EVwAx2CPi63uXtSubrwyL4nxt1tUJ4AThze8GQzhoI4waIs'

const iconFilled = {
	fontVariationSettings: "'FILL' 1, 'wght' 400, 'GRAD' 0, 'opsz' 24" as const,
}

export function TheLocal() {
	return (
		<div className="min-h-dvh bg-background text-on-surface antialiased">
			<SiteHeader />

			<main className="pt-20">
				<section className="relative overflow-hidden bg-gradient-to-b from-white to-surface-container-low pb-32 pt-20">
					<div className="relative z-10 mx-auto max-w-7xl px-8 text-center">
						<h1 className="mb-6 text-5xl font-extrabold tracking-tight text-on-surface md:text-7xl">
							Your local life, unlocked.
						</h1>
						<p className="mx-auto mb-12 max-w-2xl text-lg leading-relaxed text-on-surface-variant md:text-xl">
							Your secure AA (Account Abstraction) digital vault for local independent brands. Currently in
							open Beta.
						</p>
						<div className="flex flex-col items-center justify-center gap-4 md:flex-row">
							<a
								href="https://testflight.apple.com/join/jAc4kSsn"
								target="_blank"
								rel="noopener noreferrer"
								className="flex items-center gap-3 rounded-full bg-gradient-to-br from-primary to-primary-container px-8 py-4 font-semibold text-white shadow-lg transition-all hover:opacity-90 active:scale-95"
							>
								<span className="material-symbols-outlined" style={iconFilled}>
									ios
								</span>
								Apple TestFlight
							</a>
							<a
								href="https://play.google.com/store/apps/details?id=com.beamio.caehtrees"
								target="_blank"
								rel="noopener noreferrer"
								className="flex items-center gap-3 rounded-full border border-outline-variant/30 bg-white px-8 py-4 font-semibold text-on-surface transition-all hover:bg-surface-container-low active:scale-95"
							>
								<span className="material-symbols-outlined">Android</span>
								Google Play
							</a>
							<a
								href="https://verra.network/app/"
								target="_blank"
								rel="noopener noreferrer"
								className="flex items-center gap-3 rounded-full border border-outline-variant/30 bg-white px-8 py-4 font-semibold text-on-surface transition-all hover:bg-surface-container-low active:scale-95"
							>
								<span className="material-symbols-outlined">open_in_browser</span>
								Launch Web App
							</a>
						</div>
					</div>
					<div className="pointer-events-none absolute left-1/2 top-1/2 h-[120%] w-[120%] -translate-x-1/2 -translate-y-1/2 bg-[radial-gradient(circle_at_50%_50%,rgba(21,98,240,0.05)_0%,transparent_70%)]" />
				</section>

				<section className="bg-white py-32">
					<div className="mx-auto grid max-w-7xl items-center gap-20 px-8 md:grid-cols-2">
						<div className="order-2 md:order-1">
							<div className="relative mx-auto h-[600px] w-72 overflow-hidden rounded-[3rem] bg-slate-900 p-3 shadow-2xl ring-8 ring-slate-100">
								<div className="flex h-full w-full flex-col overflow-hidden rounded-[2.2rem] bg-white pt-12">
									<div className="space-y-6 px-6">
										<div className="flex items-center justify-between">
											<div className="h-10 w-10 rounded-full bg-surface-container-high" />
											<span className="material-symbols-outlined text-on-surface-variant">
												notifications
											</span>
										</div>
										<div className="space-y-1">
											<p className="text-xs font-bold uppercase tracking-widest text-on-surface-variant">
												Total Balance
											</p>
											<p className="text-3xl font-bold tracking-tighter font-mono">$1,452.80</p>
										</div>
										<div className="relative group">
											<div className="absolute -inset-4 rounded-3xl bg-primary/10 opacity-50 blur-xl" />
											<div className="relative flex aspect-square items-center justify-center rounded-3xl border-2 border-primary/20 bg-white p-6">
												<div className="flex h-full w-full items-center justify-center overflow-hidden rounded-lg bg-slate-50">
													<img
														src={IMG_VAULT_QR}
														alt="Dynamic pay QR code"
														className="h-full w-full object-cover mix-blend-multiply opacity-80"
													/>
												</div>
											</div>
											<div className="mt-4 flex justify-center">
												<div className="rounded-full bg-surface-container-high px-4 py-1">
													<p className="text-[10px] font-bold uppercase tracking-widest text-on-surface-variant">
														Expires in 0:45
													</p>
												</div>
											</div>
										</div>
									</div>
								</div>
							</div>
						</div>
						<div className="order-1 space-y-8 md:order-2">
							<h2 className="text-4xl font-bold tracking-tight text-on-surface md:text-5xl">
								Next-generation smart wallet.
							</h2>
							<p className="text-xl leading-relaxed text-on-surface-variant">
								Powered by Account Abstraction. Hold balances, track vouchers, and route payments instantly
								without traditional bank fees.
							</p>
							<div className="space-y-6 pt-4">
								<div className="flex items-start gap-4">
									<div className="rounded-2xl bg-primary-container/10 p-3">
										<span className="material-symbols-outlined text-primary">security</span>
									</div>
									<div>
										<h4 className="font-bold text-on-surface">Biometric Recovery</h4>
										<p className="text-on-surface-variant">Never lose access. Your face is your private key.</p>
									</div>
								</div>
								<div className="flex items-start gap-4">
									<div className="rounded-2xl bg-primary-container/10 p-3">
										<span className="material-symbols-outlined text-primary">bolt</span>
									</div>
									<div>
										<h4 className="font-bold text-on-surface">Zero Gas Fees</h4>
										<p className="text-on-surface-variant">Smooth transactions sponsored by our network.</p>
									</div>
								</div>
							</div>
						</div>
					</div>
				</section>

				<section className="bg-surface-container-low py-32">
					<div className="mx-auto max-w-7xl px-8">
						<div className="mb-20 text-center">
							<h2 className="mb-6 text-4xl font-bold tracking-tight text-on-surface md:text-5xl">
								Show or Tap. Purely seamless.
							</h2>
							<p className="mx-auto max-w-2xl text-xl text-on-surface-variant">
								Open the app to show your dynamic QR code for the merchant to scan, or simply tap your secure
								physical NFC card on the back of the merchant&apos;s phone.
							</p>
						</div>
						<div className="grid gap-8 md:grid-cols-2">
							<div className="flex flex-col items-center justify-center space-y-8 rounded-[2rem] bg-white p-12 shadow-[0_4px_24px_rgba(0,0,0,0.02)]">
								<div className="relative aspect-square w-64 overflow-hidden rounded-3xl bg-surface-container-low">
									<img
										src={IMG_QR_SCAN}
										alt="Phone showing dynamic QR for merchant scan"
										className="h-full w-full object-cover"
									/>
								</div>
								<div className="text-center">
									<h3 className="mb-2 text-2xl font-bold">Dynamic QR Scan</h3>
									<p className="text-on-surface-variant">Generate a secure one-time code.</p>
								</div>
							</div>
							<div className="relative flex flex-col items-center justify-center space-y-8 overflow-hidden rounded-[2rem] bg-white p-12 shadow-[0_4px_24px_rgba(0,0,0,0.02)]">
								<div className="group relative flex h-48 w-full max-w-xs flex-col justify-between overflow-hidden rounded-2xl bg-gradient-to-br from-slate-900 to-slate-800 p-8 shadow-2xl">
									<div className="pointer-events-none absolute inset-0 opacity-20">
										<img src={IMG_NFC_WAVE} alt="" className="h-full w-full object-cover" />
									</div>
									<div className="relative z-10 flex items-start justify-between">
										<span className="material-symbols-outlined text-4xl text-white/40">contactless</span>
										<span className="text-xl font-bold tracking-tighter text-white">VERRA</span>
									</div>
									<div className="relative z-10">
										<p className="text-[10px] font-bold uppercase tracking-widest text-white/40">
											TAG424 DNA SECURE
										</p>
									</div>
								</div>
								<div className="text-center">
									<h3 className="mb-2 text-2xl font-bold">TAG424 NFC Card</h3>
									<p className="text-on-surface-variant">Physical security with modern elegance.</p>
								</div>
							</div>
						</div>
					</div>
				</section>

				<section className="bg-white py-32">
					<div className="mx-auto max-w-7xl px-8">
						<div className="mb-16 flex flex-col items-end justify-between gap-8 md:flex-row">
							<div className="max-w-2xl">
								<h2 className="mb-6 text-4xl font-bold tracking-tight text-on-surface md:text-5xl">
									Coming to your neighborhood.
								</h2>
								<p className="text-xl leading-relaxed text-on-surface-variant">
									We are currently onboarding our first wave of visionary independent merchants. Be the
									first to use your vault locally.
								</p>
							</div>
							<div className="flex gap-4">
								<button
									type="button"
									className="flex h-12 w-12 items-center justify-center rounded-full bg-surface-container-high text-on-surface transition-colors hover:bg-surface-container-highest"
									aria-label="Previous"
								>
									<span className="material-symbols-outlined">arrow_back</span>
								</button>
								<button
									type="button"
									className="flex h-12 w-12 items-center justify-center rounded-full bg-surface-container-high text-on-surface transition-colors hover:bg-surface-container-highest"
									aria-label="Next"
								>
									<span className="material-symbols-outlined">arrow_forward</span>
								</button>
							</div>
						</div>
						<div className="grid gap-6 md:grid-cols-3">
							<div className="group space-y-12 rounded-[2rem] border border-outline-variant/10 bg-surface-container-low/50 p-10 transition-all hover:bg-white hover:shadow-[0_20px_40px_rgba(0,0,0,0.04)]">
								<div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-white shadow-sm transition-transform group-hover:scale-110">
									<span className="material-symbols-outlined text-3xl text-primary">local_cafe</span>
								</div>
								<div className="space-y-2">
									<h3 className="text-2xl font-bold">Local Coffee House</h3>
									<p className="text-on-surface-variant">Craft roasts and morning rituals.</p>
								</div>
								<div className="flex items-center gap-2 pt-4 text-sm font-semibold text-primary">
									<span>View Partners</span>
									<span className="material-symbols-outlined text-sm">east</span>
								</div>
							</div>
							<div className="group space-y-12 rounded-[2rem] border border-outline-variant/10 bg-surface-container-low/50 p-10 transition-all hover:bg-white hover:shadow-[0_20px_40px_rgba(0,0,0,0.04)]">
								<div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-white shadow-sm transition-transform group-hover:scale-110">
									<span className="material-symbols-outlined text-3xl text-primary">bakery_dining</span>
								</div>
								<div className="space-y-2">
									<h3 className="text-2xl font-bold">Neighborhood Bakery</h3>
									<p className="text-on-surface-variant">Artisan dough and daily bakes.</p>
								</div>
								<div className="flex items-center gap-2 pt-4 text-sm font-semibold text-primary">
									<span>View Partners</span>
									<span className="material-symbols-outlined text-sm">east</span>
								</div>
							</div>
							<div className="group space-y-12 rounded-[2rem] border border-outline-variant/10 bg-surface-container-low/50 p-10 transition-all hover:bg-white hover:shadow-[0_20px_40px_rgba(0,0,0,0.04)]">
								<div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-white shadow-sm transition-transform group-hover:scale-110">
									<span className="material-symbols-outlined text-3xl text-primary">restaurant</span>
								</div>
								<div className="space-y-2">
									<h3 className="text-2xl font-bold">Artisan Dining</h3>
									<p className="text-on-surface-variant">Elevated cuisine from independent chefs.</p>
								</div>
								<div className="flex items-center gap-2 pt-4 text-sm font-semibold text-primary">
									<span>View Partners</span>
									<span className="material-symbols-outlined text-sm">east</span>
								</div>
							</div>
						</div>
					</div>
				</section>

				<section className="mx-auto max-w-7xl px-8 py-24">
					<div className="relative overflow-hidden rounded-[3rem] bg-primary p-16 text-center text-white">
						<div className="relative z-10 space-y-8">
							<h2 className="text-4xl font-bold">Ready to reclaim your local economy?</h2>
							<p className="mx-auto max-w-xl text-lg text-blue-100">
								Join thousands of early adopters currently testing the VERRA vault in the wild.
							</p>
							<button
								type="button"
								className="rounded-full bg-white px-10 py-4 text-lg font-bold text-primary transition-colors hover:bg-blue-50 active:scale-95"
							>
								Get Early Access
							</button>
						</div>
						<div className="absolute -bottom-20 -right-20 h-80 w-80 rounded-full bg-white/10 blur-3xl" />
						<div className="absolute -left-20 -top-20 h-80 w-80 rounded-full bg-blue-400/20 blur-3xl" />
					</div>
				</section>
			</main>

			<SiteFooter />
		</div>
	)
}
