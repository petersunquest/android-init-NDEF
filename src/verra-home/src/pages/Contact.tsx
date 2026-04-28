import { FormEvent, useEffect } from 'react'
import { SiteFooter } from '../components/SiteFooter'
import { SiteHeader } from '../components/SiteHeader'

const iconFilled = {
	fontVariationSettings: "'FILL' 1, 'wght' 400, 'GRAD' 0, 'opsz' 24" as const,
}

const inputClassName =
	'w-full rounded border-none bg-surface-container-highest px-6 py-4 text-on-surface transition-all placeholder:text-outline-variant focus:outline-none focus:ring-2 focus:ring-primary-container'

export function Contact() {
	useEffect(() => {
		document.title = 'Contact | Verra'
	}, [])

	function handleSubmit(e: FormEvent<HTMLFormElement>) {
		e.preventDefault()
	}

	return (
		<div className="min-h-dvh bg-background font-body text-on-surface selection:bg-primary-container selection:text-on-primary-container antialiased">
			<SiteHeader />

			<main className="pb-20 pt-20">
				<section className="bg-surface-container-low px-6 py-20">
					<div className="mx-auto max-w-7xl">
						<h1 className="mb-8 max-w-4xl text-6xl font-black leading-[0.9] tracking-tighter text-on-surface md:text-8xl">
							We are here to help.
						</h1>
						<p className="max-w-2xl text-xl leading-relaxed text-on-surface-variant md:text-2xl">
							Support for your decentralized, digital store-membership operating system. Our technical and onboarding
							teams are ready to assist with your infrastructure needs.
						</p>
					</div>
				</section>

				<section className="mx-auto max-w-7xl px-6 py-20">
					<div className="grid grid-cols-1 items-start gap-16 lg:grid-cols-2">
						<div className="space-y-6">
							<div className="flex items-start gap-6 rounded-lg border border-white/50 bg-surface-container-lowest p-8 shadow-[0_4px_24px_rgba(0,0,0,0.04)] transition-shadow hover:shadow-lg">
								<div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-primary-container/10 text-primary-container">
									<span className="material-symbols-outlined" style={iconFilled}>
										desktop_windows
									</span>
								</div>
								<div>
									<h3 className="mb-2 text-xl font-bold tracking-tight">Software &amp; OS Support</h3>
									<p className="mb-4 leading-relaxed text-on-surface-variant">
										For beta users experiencing UI/UX issues or requiring technical assistance with the Verra app.
									</p>
									<a
										className="font-semibold text-primary-container decoration-2 underline-offset-4 hover:underline"
										href="mailto:support@verra.local"
									>
										support@verra.local
									</a>
								</div>
							</div>

							<div className="flex items-start gap-6 rounded-lg border border-white/50 bg-surface-container-lowest p-8 shadow-[0_4px_24px_rgba(0,0,0,0.04)] transition-shadow hover:shadow-lg">
								<div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-primary-container/10 text-primary-container">
									<span className="material-symbols-outlined" style={iconFilled}>
										storefront
									</span>
								</div>
								<div>
									<h3 className="mb-2 text-xl font-bold tracking-tight">Merchant Onboarding</h3>
									<p className="mb-4 leading-relaxed text-on-surface-variant">
										For independent businesses ready to deploy our closed-loop infrastructure.
									</p>
									<a
										className="font-semibold text-primary-container decoration-2 underline-offset-4 hover:underline"
										href="mailto:partners@verra.local"
									>
										partners@verra.local
									</a>
								</div>
							</div>

							<div className="flex items-start gap-6 rounded-lg border border-white/50 bg-surface-container-lowest p-8 shadow-[0_4px_24px_rgba(0,0,0,0.04)] transition-shadow hover:shadow-lg">
								<div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-primary-container/10 text-primary-container">
									<span className="material-symbols-outlined" style={iconFilled}>
										security
									</span>
								</div>
								<div>
									<h3 className="mb-2 text-xl font-bold tracking-tight">Legal &amp; Infrastructure</h3>
									<p className="mb-4 leading-relaxed text-on-surface-variant">
										For inquiries regarding our non-custodial architecture and compliance frameworks.
									</p>
									<a
										className="font-semibold text-primary-container decoration-2 underline-offset-4 hover:underline"
										href="mailto:legal@verra.local"
									>
										legal@verra.local
									</a>
								</div>
							</div>
						</div>

						<div className="rounded-lg border border-white/50 bg-surface-container-lowest p-10 shadow-[0_4px_24px_rgba(0,0,0,0.04)] md:p-12">
							<form className="space-y-8" onSubmit={handleSubmit}>
								<div className="grid grid-cols-1 gap-8">
									<div className="space-y-2">
										<label className="ml-1 text-sm font-bold tracking-tight text-on-surface-variant" htmlFor="contact-name">
											Your Name
										</label>
										<input
											id="contact-name"
											name="name"
											type="text"
											autoComplete="name"
											className={inputClassName}
											placeholder="John Doe"
										/>
									</div>
									<div className="space-y-2">
										<label className="ml-1 text-sm font-bold tracking-tight text-on-surface-variant" htmlFor="contact-email">
											Email Address
										</label>
										<input
											id="contact-email"
											name="email"
											type="email"
											autoComplete="email"
											className={inputClassName}
											placeholder="john@example.com"
										/>
									</div>
									<div className="space-y-2">
										<label
											className="ml-1 text-sm font-bold tracking-tight text-on-surface-variant"
											htmlFor="contact-inquiry-type"
										>
											Inquiry Type
										</label>
										<div className="relative">
											<select
												id="contact-inquiry-type"
												name="inquiry"
												className={`${inputClassName} appearance-none pr-12`}
												defaultValue="Merchant OS Setup"
											>
												<option>Merchant OS Setup</option>
												<option>Software Bug Report</option>
												<option>Partnerships</option>
											</select>
											<span className="pointer-events-none absolute right-4 top-1/2 -translate-y-1/2 material-symbols-outlined text-on-surface-variant">
												expand_more
											</span>
										</div>
									</div>
									<div className="space-y-2">
										<label className="ml-1 text-sm font-bold tracking-tight text-on-surface-variant" htmlFor="contact-message">
											Message
										</label>
										<textarea
											id="contact-message"
											name="message"
											rows={5}
											className={`${inputClassName} resize-none`}
											placeholder="How can we help you?"
										/>
									</div>
								</div>
								<button
									type="submit"
									className="flex w-full items-center justify-center gap-2 rounded-full bg-gradient-to-r from-[#004bc3] to-[#1562f0] py-5 text-lg font-bold text-white shadow-lg transition-all hover:scale-[1.02] hover:shadow-primary/20 active:scale-[0.98]"
								>
									Send Message
									<span className="material-symbols-outlined">send</span>
								</button>
							</form>
						</div>
					</div>
				</section>
			</main>

			<SiteFooter />
		</div>
	)
}
