import { Link } from 'react-router-dom'
import { SiteFooter } from '../components/SiteFooter'
import { SiteHeader } from '../components/SiteHeader'

const HERO_IMAGE =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuD7dmpmXqLEccBpf8p6IuLjnlNPi_94V2dVYhavHIe1wYAB7RWstXkQ3PPVqbexVfvY--f66JhscDTMexjnAp4eF1__ZWYW5sUJvi5NyGYGZcrbESlYSkV5u0FrYJKecdKVDRNm_P0hsIWNohUYR3phgKV7PLde18JkNmKpfSN7CMVvC3sTAp7S1aftFw8SfPtiXfRyLn5n5EU4BoRN4drI-SKtBYbsh3tUzTVPozO3ufY60ZKVeihkXTud0A23oDF3opPwBGxaDduo'

const PORTRAIT_1 =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuDYoOwQs-5gJol2OJqEQP1zej6R1tJrDtihJ20IBie4HKDVsXU7lPHQ7z3gWgZNJRqlnmqE3a8GjtGFWE40wshp9rsf7Hjy8rAFjYKnZR7st9zsKvA-ZzR5nv1KSZCswf4QzBhHcdQkgSp2qoIhTZ781MwrJr3G3HlGcfOY_KKjyKAaE4jzNB9GJViFdJm91hrfEJuP7V1dlNzUerlTmymHMbv4oGfOcKTaTyeLXy2Z8lXTI4ijHcfrsttdZTWA4PnV41NURJ3qdNX0'

const PORTRAIT_2 =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuB6AXZ-Smh0IngtbipODnzzH9E5IwX_3Lnnqu1_wa4EUrSd9vkDH7C0RzypUMFkhLmBfBbPeTXOMtK53r1UskAYyMD3_lV4P9Uw6aZTMi_3f7Zg4Yl8wajdWiShOIfibI1OOd9ERzbbK1_7ajDbX3ETwaW8G6FWDbJuzAeCdRipo8XsoU7X06vMnxZeZ9QMYfdgQMDteuphTaZpVNr3vMgwEuG93BFH4MyxIbJWKjk1ALssVBPtdvAPxrOAEnEO4_rwCdbRCLofvPA-'

const PORTRAIT_3 =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuC-2SnrCcgW-pahqH-uUub2cByq0OfFmRdBxDfzSItUCenCPiUitCKPT5_Pe0hZbFLCMr3z6SKJeaD9dI96YjEFeHfi5xUh9hZGDdaBDaygQ3dybjYRZ4nSAHWHZLgLrF-fw3HccIEygIfb7zJjpJhyzNP_rUH3jvxsFi17wmxnBd6E2vPh-Kos7xP77TOMW6ybj0eGwkf1NXuNpfNKLb2JiGgBn5d7drZ7QydBzlDFP50MyJ7uW4SfF8WfquN1pBVRWeTzi0FmpHjU'

const TAP_IMAGE =
	'https://lh3.googleusercontent.com/aida-public/AB6AXuCUQR1H40QBQwPCmKW_o-Ea-28G2hAPU1eJksKncuboMZxViL5ofYzpTEWDnssIakGA4XAuq1JiHSW0Djtu66ciI7BRbr8UyanPyeIGdfQVuJNm5obufFyJDq5oEn_jd8wfOacnbfsaoEt2Zz8Le1tLMZZv2WcZXYGHOCRUjMt_Vk6UYXMuyXIJZGFi3ziv6KmbjSskfo6o2MzyRhnWNzKdRzJkbA2d0LG6axGa6nJDa5fuRxc9i3dT0ZOphEBgV26Y0botB80NHaea'

const iconFilled = {
	fontVariationSettings: "'FILL' 1, 'wght' 400, 'GRAD' 0, 'opsz' 24" as const,
}

export function Impact() {
	return (
		<div className="min-h-dvh bg-background font-body text-on-surface selection:bg-primary-fixed selection:text-on-primary-fixed antialiased">
			<SiteHeader />
			<main className="pt-20">
				<section className="relative flex min-h-[751px] items-center overflow-hidden">
					<div className="absolute inset-0 z-0">
						<img
							alt="Warm artisan bakery: baker hands bread to a neighbor"
							className="h-full w-full object-cover brightness-110 blur-sm"
							src={HERO_IMAGE}
						/>
						<div className="absolute inset-0 bg-white/70 backdrop-blur-[2px]" />
					</div>
					<div className="relative z-10 mx-auto w-full max-w-7xl px-8">
						<div className="max-w-3xl">
							<h1 className="font-headline mb-8 text-7xl font-extrabold leading-[1.1] tracking-tight text-on-surface md:text-8xl">
								One donation. <br />
								<span className="text-primary">Twice the impact.</span>
							</h1>
							<p className="mb-12 max-w-2xl text-xl leading-relaxed text-on-surface-variant md:text-2xl">
								Traditional philanthropy leaks value to transaction fees and big-box retailers. Verra routes{' '}
								<span className="text-mono font-bold">100%</span> of donations to those in need, and ensures every
								dollar is spent strictly at local independent businesses.
							</p>
							<div className="flex flex-wrap gap-4">
								<button
									type="button"
									className="flex items-center gap-2 rounded-full bg-[#2D4A3E] px-8 py-4 font-semibold text-white transition-all hover:opacity-90"
								>
									Partner as an NGO
								</button>
								<button
									type="button"
									className="rounded-full border-2 border-on-surface px-8 py-4 font-semibold text-on-surface transition-all hover:bg-on-surface/5"
								>
									See the Journey
								</button>
							</div>
						</div>
					</div>
				</section>

				<section className="mx-auto max-w-7xl px-8 py-24">
					<div className="grid gap-8 md:grid-cols-2">
						<div className="flex flex-col justify-between rounded-lg bg-surface-container-low p-12">
							<div>
								<span className="mb-6 inline-block rounded-full bg-surface-variant px-4 py-1 text-sm font-semibold text-on-surface-variant">
									The Legacy Model
								</span>
								<h3 className="font-headline mb-6 text-4xl font-bold text-on-surface">The old charity.</h3>
								<p className="text-lg leading-relaxed text-on-surface-variant">
									Donations are eaten by <span className="text-mono font-bold">3%</span> processing fees. When
									funds finally reach the vulnerable, they are often spent at multinational supermarkets,
									draining wealth from the community.
								</p>
							</div>
							<div className="mt-12 h-1 overflow-hidden rounded-full bg-surface-variant">
								<div className="h-full w-1/3 bg-error" />
							</div>
						</div>
						<div className="flex flex-col justify-between rounded-lg bg-[#EBF5EE] p-12">
							<div>
								<span className="mb-6 inline-block rounded-full bg-[#D1EBD9] px-4 py-1 text-sm font-semibold text-[#1E392A]">
									The Verra Way
								</span>
								<h3 className="font-headline mb-6 text-4xl font-bold text-[#1E392A]">The local multiplier.</h3>
								<p className="text-lg leading-relaxed text-[#2D4A3E]">
									Zero processing fees on donations. Funds are distributed as smart digital vouchers that can ONLY
									be spent at local independent bakeries, cafes, and grocers. You feed a neighbor AND keep a
									local shop alive.
								</p>
							</div>
							<div className="mt-12 h-1 overflow-hidden rounded-full bg-[#D1EBD9]">
								<div className="h-full w-full bg-[#2D4A3E]" />
							</div>
						</div>
					</div>
				</section>

				<section className="bg-surface-container-low/30 py-24">
					<div className="mx-auto max-w-7xl px-8">
						<div className="mb-20 text-center">
							<h2 className="font-headline mb-4 text-5xl font-bold tracking-tight text-on-surface">
								How closed-loop giving works.
							</h2>
							<div className="mx-auto h-1 w-24 rounded-full bg-primary" />
						</div>
						<div className="grid gap-12 md:grid-cols-3">
							<div className="rounded-lg border border-outline-variant/10 bg-white p-10 shadow-[0_4px_24px_rgba(0,0,0,0.02)]">
								<div className="mb-8 flex h-16 w-16 items-center justify-center rounded-2xl bg-primary-fixed">
									<span className="material-symbols-outlined text-3xl text-primary" style={iconFilled}>
										favorite
									</span>
								</div>
								<h4 className="font-headline mb-4 text-2xl font-bold text-on-surface">Step 1: 100% Give.</h4>
								<p className="leading-relaxed text-on-surface-variant">
									Locals and philanthropists donate funds with absolute zero transaction fees. Every cent you give
									goes directly to human support.
								</p>
							</div>
							<div className="rounded-lg border border-outline-variant/10 bg-white p-10 shadow-[0_4px_24px_rgba(0,0,0,0.02)]">
								<div className="mb-8 flex h-16 w-16 items-center justify-center rounded-2xl bg-secondary-fixed">
									<span className="material-symbols-outlined text-3xl text-secondary">account_tree</span>
								</div>
								<h4 className="font-headline mb-4 text-2xl font-bold text-on-surface">
									Step 2: Smart Distribution.
								</h4>
								<p className="leading-relaxed text-on-surface-variant">
									NGOs route these funds directly to the digital vaults of vulnerable community members via the
									Verra dashboard with instant audit trails.
								</p>
							</div>
							<div className="rounded-lg border border-outline-variant/10 bg-white p-10 shadow-[0_4px_24px_rgba(0,0,0,0.02)]">
								<div className="mb-8 flex h-16 w-16 items-center justify-center rounded-2xl bg-tertiary-fixed">
									<span className="material-symbols-outlined text-3xl text-tertiary">storefront</span>
								</div>
								<h4 className="font-headline mb-4 text-2xl font-bold text-on-surface">
									Step 3: Dignified Spending.
								</h4>
								<p className="leading-relaxed text-on-surface-variant">
									Recipients tap-to-pay at local independent shops. The money stays in the neighborhood, supporting
									the local economic engine.
								</p>
							</div>
						</div>
					</div>
				</section>

				<section className="bg-[#F7F9FC] py-32">
					<div className="mx-auto max-w-7xl px-8">
						<div className="grid items-center gap-20 md:grid-cols-2">
							<div>
								<h2 className="font-headline mb-8 text-6xl font-extrabold tracking-tight text-on-surface">
									Dignity is a human right.
								</h2>
								<p className="text-2xl leading-relaxed text-on-surface-variant">
									No more paper food stamps or separate checkout lines. With Verra, a community member seeking
									assistance pays exactly like everyone else: a seamless, instant tap with their smartphone or
									Verra physical card.
								</p>
								<div className="mt-8 flex items-center gap-4">
									<div className="flex -space-x-4">
										<div className="h-12 w-12 overflow-hidden rounded-full border-4 border-white bg-surface-container-high">
											<img
												src={PORTRAIT_1}
												alt="Community member portrait"
												className="h-full w-full object-cover"
											/>
										</div>
										<div className="h-12 w-12 overflow-hidden rounded-full border-4 border-white bg-surface-container-high">
											<img
												src={PORTRAIT_2}
												alt="Community member portrait"
												className="h-full w-full object-cover"
											/>
										</div>
										<div className="h-12 w-12 overflow-hidden rounded-full border-4 border-white bg-surface-container-high">
											<img
												src={PORTRAIT_3}
												alt="Community member portrait"
												className="h-full w-full object-cover"
											/>
										</div>
									</div>
									<span className="font-semibold text-on-surface">Pride and privacy, fully restored.</span>
								</div>
							</div>
							<div className="group relative">
								<div className="absolute -inset-4 rounded-xl bg-primary/5 blur-3xl transition-all duration-700 group-hover:bg-primary/10" />
								<div className="relative overflow-hidden rounded-lg shadow-[0_32px_64px_-12px_rgba(0,0,0,0.12)]">
									<img
										alt="Verra NFC card tapping a merchant phone"
										className="aspect-[4/5] w-full object-cover"
										src={TAP_IMAGE}
									/>
								</div>
							</div>
						</div>
					</div>
				</section>

				<section className="mx-auto mb-24 max-w-7xl px-8">
					<div className="rounded-[2rem] bg-gradient-to-br from-[#1E3F33] to-[#2A5A48] px-8 py-20 text-center shadow-xl">
						<h2 className="font-headline mb-10 text-5xl font-bold tracking-tight text-white">
							Ready to empower your neighborhood?
						</h2>
						<div className="flex justify-center">
							<Link
								to="/contact"
								className="inline-block rounded-full bg-white px-10 py-4 text-lg font-bold text-[#1E3F33] transition-transform hover:scale-105 active:opacity-90"
							>
								Apply as an NGO Partner
							</Link>
						</div>
					</div>
				</section>
			</main>

			<SiteFooter />
		</div>
	)
}
