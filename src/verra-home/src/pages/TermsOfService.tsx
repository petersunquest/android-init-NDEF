import { useEffect } from 'react'
import { SiteFooter } from '../components/SiteFooter'
import { SiteHeader } from '../components/SiteHeader'

export function TermsOfService() {
	useEffect(() => {
		document.title = 'Terms of Service | Verra'
	}, [])

	return (
		<div className="min-h-dvh bg-background font-body text-on-surface selection:bg-primary-container selection:text-white antialiased">
			<SiteHeader />

			<main className="pt-20">
				<section className="bg-[#F4F7FF] px-6 py-24 md:py-32">
					<div className="mx-auto max-w-4xl">
						<p className="mb-6 text-xs font-semibold uppercase tracking-widest text-primary">Legal Documentation</p>
						<h1 className="mb-8 text-6xl font-extrabold tracking-tighter text-on-surface md:text-8xl">
							Terms of Service.
						</h1>
						<p className="mb-6 max-w-2xl text-xl font-light leading-relaxed text-on-surface-variant md:text-2xl">
							The operational framework for our decentralized, non-custodial local commerce network.
						</p>
						<div className="flex items-center gap-4 font-mono text-sm uppercase tracking-wider text-outline">
							<span>Effective Date: April 2026</span>
							<span className="h-1 w-1 rounded-full bg-outline" />
							<span>Beta Release Agreement</span>
						</div>
					</div>
				</section>

				<section className="bg-white px-6 py-24">
					<div className="mx-auto max-w-3xl space-y-24">
						<div className="group">
							<div className="flex items-start gap-8">
								<span className="select-none font-mono text-4xl font-black text-surface-container-highest">01</span>
								<div className="space-y-4">
									<h2 className="text-2xl font-bold tracking-tight text-on-surface">Non-Custodial Infrastructure</h2>
									<p className="text-lg font-light leading-relaxed text-on-surface-variant">
										VERRA operates exclusively as a non-custodial technology network and data routing
										infrastructure provider. VERRA does not provide fiat collection services and does not custody
										your digital assets. This ensures maximum sovereignty over your local economic data and
										digital points.
									</p>
								</div>
							</div>
						</div>

						<div className="group">
							<div className="flex items-start gap-8">
								<span className="select-none font-mono text-4xl font-black text-surface-container-highest">02</span>
								<div className="space-y-4">
									<h2 className="text-2xl font-bold tracking-tight text-on-surface">
										Independent Merchant Closed-Loops
									</h2>
									<p className="text-lg font-light leading-relaxed text-on-surface-variant">
										The Merchant acts as the Sole Legal Issuer and primary obligor of their respective digital
										closed-loop stored value. VERRA strictly prohibits cross-merchant commingled fund pools.
										Each ecosystem is mathematically and legally isolated to preserve the integrity of local
										commerce.
									</p>
								</div>
							</div>
						</div>

						<div className="group">
							<div className="flex items-start gap-8">
								<span className="select-none font-mono text-4xl font-black text-surface-container-highest">03</span>
								<div className="space-y-4">
									<h2 className="text-2xl font-bold tracking-tight text-on-surface">Third-Party Fiat Services</h2>
									<p className="text-lg font-light leading-relaxed text-on-surface-variant">
										All fiat purchase and exchange services are directly provided by independent, licensed third
										parties. VERRA is perfectly isolated from fiat handling, acting solely as a communication
										layer between users and regulated financial entities.
									</p>
								</div>
							</div>
						</div>

						<div className="group">
							<div className="flex items-start gap-8">
								<span className="select-none font-mono text-4xl font-black text-surface-container-highest">04</span>
								<div className="space-y-4">
									<h2 className="text-2xl font-bold tracking-tight text-on-surface">
										Consumer Rights &amp; Zero Expiry
									</h2>
									<p className="text-lg font-light leading-relaxed text-on-surface-variant">
										Digital stored-value balances held within your vault carry absolutely no system-imposed
										expiration dates and are not subject to consumer-facing activation fees. Your local spending
										power remains intact for as long as the issuing merchant remains operational.
									</p>
								</div>
							</div>
						</div>

						<div className="border-t-0 border-outline-variant/10 pt-12">
							<div className="rounded-lg bg-surface-container-low p-8">
								<p className="text-sm italic leading-relaxed text-on-surface-variant">
									By accessing the Verra infrastructure, you acknowledge that you have read and understood the
									decentralized nature of these services. This documentation is subject to periodic updates to
									reflect the evolving standards of non-custodial technology.
								</p>
							</div>
						</div>
					</div>
				</section>
			</main>

			<SiteFooter />
		</div>
	)
}
