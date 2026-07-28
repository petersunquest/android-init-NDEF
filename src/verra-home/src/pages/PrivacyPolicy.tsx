import { useEffect } from 'react'
import { SiteFooter } from '../components/SiteFooter'
import { SiteHeader } from '../components/SiteHeader'

function SidebarNavLink({ id, label }: { id: string; label: string }) {
	return (
		<a
			className="group flex items-center justify-between rounded-xl p-4 transition-all duration-200 hover:bg-surface-container-low"
			href={`#${id}`}
		>
			<span className="font-semibold text-on-surface transition-colors group-hover:text-primary">{label}</span>
			<span className="material-symbols-outlined text-outline-variant transition-colors group-hover:text-primary">
				chevron_right
			</span>
		</a>
	)
}

export function PrivacyPolicy() {
	useEffect(() => {
		document.title = 'Privacy Policy | Verra'
	}, [])

	return (
		<div className="min-h-dvh bg-background font-body text-on-surface selection:bg-primary-container selection:text-on-primary-container antialiased">
			<SiteHeader />

			<main className="min-h-screen pt-20">
				<section className="bg-surface-container-low px-6 py-24 md:py-32">
					<div className="mx-auto max-w-7xl">
						<span className="mb-4 block text-xs font-bold uppercase tracking-widest text-primary">Security Standards</span>
						<h1 className="mb-8 max-w-4xl text-5xl font-black tracking-tighter text-on-surface md:text-8xl">
							Privacy Policy
						</h1>
						<p className="mb-8 max-w-2xl text-xl leading-relaxed text-on-surface-variant md:text-2xl">
							Zero-Trace Privacy by design. We build network infrastructure, not data silos.
						</p>
						<div className="inline-flex items-center rounded-full bg-surface-container-highest px-4 py-2 text-xs font-medium text-on-surface-variant">
							Last Updated: April 2026
						</div>
					</div>
				</section>

				<section className="bg-surface-container-lowest px-6 py-20">
					<div className="mx-auto grid max-w-7xl grid-cols-1 gap-16 md:gap-24 lg:grid-cols-12">
						<aside className="hidden lg:col-span-4 lg:block">
							<div className="sticky top-32 space-y-2">
								<SidebarNavLink id="architecture" label="1. Zero-Trace Architecture" />
								<SidebarNavLink id="key-control" label="2. Local Key Control" />
								<SidebarNavLink id="erasure" label="3. Cryptographic Erasure" />
								<SidebarNavLink id="no-pii" label="4. No PII Collection" />
							</div>
						</aside>

						<div className="no-scrollbar -mx-6 flex gap-4 overflow-x-auto pb-4 px-6 lg:hidden">
							<a
								className="whitespace-nowrap rounded-full bg-surface-container-low px-6 py-3 text-sm font-bold"
								href="#architecture"
							>
								1. Architecture
							</a>
							<a
								className="whitespace-nowrap rounded-full bg-surface-container-low px-6 py-3 text-sm font-bold"
								href="#key-control"
							>
								2. Key Control
							</a>
							<a
								className="whitespace-nowrap rounded-full bg-surface-container-low px-6 py-3 text-sm font-bold"
								href="#erasure"
							>
								3. Erasure
							</a>
							<a
								className="whitespace-nowrap rounded-full bg-surface-container-low px-6 py-3 text-sm font-bold"
								href="#no-pii"
							>
								4. PII Policy
							</a>
						</div>

						<article className="space-y-32 lg:col-span-8">
							<div className="scroll-mt-32" id="architecture">
								<h2 className="mb-8 flex items-center gap-4 text-3xl font-black text-on-surface">
									<span className="flex h-12 w-12 items-center justify-center rounded-full bg-primary-container text-lg text-on-primary-container">
										01
									</span>
									Zero-Trace Architecture
								</h2>
								<div className="space-y-6">
									<p className="text-xl leading-relaxed text-on-surface">
										VERRA does not collect or centrally store Personally Identifiable Information (PII). Our
										infrastructure strictly records pseudonymous routing tags.
									</p>
									<p className="leading-relaxed text-on-surface-variant">
										Our commitment to privacy is rooted in the physical architecture of our network. Unlike legacy
										financial systems that create honeypots of sensitive user data, our nodes function as stateless
										relays. Traffic passing through the Verra network is encrypted end-to-end, ensuring that even
										at the hardware layer, visibility is restricted to necessary routing metadata only.
									</p>
								</div>
							</div>

							<div className="scroll-mt-32" id="key-control">
								<h2 className="mb-8 flex items-center gap-4 text-3xl font-black text-on-surface">
									<span className="flex h-12 w-12 items-center justify-center rounded-full bg-primary-container text-lg text-on-primary-container">
										02
									</span>
									Local Key Control
								</h2>
								<div className="space-y-6">
									<p className="text-xl leading-relaxed text-on-surface">
										Your private keys are exclusively controlled by your local device. VERRA cannot access, view, or
										recover your keys.
									</p>
									<p className="leading-relaxed text-on-surface-variant">
										Self-custody is the cornerstone of the Verra experience. Your cryptographic credentials never
										leave the Secure Enclave of your hardware. This means that even under legal compulsion or
										technical compromise, Verra has zero technical capability to impersonate a user or access their
										digital assets. You are the sole administrator of your identity.
									</p>
								</div>
							</div>

							<div className="scroll-mt-32" id="erasure">
								<h2 className="mb-8 flex items-center gap-4 text-3xl font-black text-on-surface">
									<span className="flex h-12 w-12 items-center justify-center rounded-full bg-primary-container text-lg text-on-primary-container">
										03
									</span>
									Cryptographic Erasure
								</h2>
								<div className="space-y-6">
									<p className="text-xl leading-relaxed text-on-surface">
										We empower your absolute Right to be Forgotten. By destroying your local private key, any
										associated on-chain data instantly degrades into an irreversible orphan hash through
										Cryptographic Erasure.
									</p>
									<p className="leading-relaxed text-on-surface-variant">
										Traditional data deletion is often incomplete, leaving forensic trails in backups. Verra utilizes
										the principle of &quot;Crypto-Shredding.&quot; By deleting the unique decryption keys held only by
										the user, the historical data associated with that identity becomes mathematically
										indistinguishable from random noise, effectively purging it from existence.
									</p>
								</div>
							</div>

							<div className="scroll-mt-32 pb-20" id="no-pii">
								<h2 className="mb-8 flex items-center gap-4 text-3xl font-black text-on-surface">
									<span className="flex h-12 w-12 items-center justify-center rounded-full bg-primary-container text-lg text-on-primary-container">
										04
									</span>
									No PII Collection
								</h2>
								<div className="space-y-6">
									<p className="text-xl leading-relaxed text-on-surface">
										Our network protocols are engineered to operate without the collection of names, emails, or
										government IDs, prioritizing anonymity at every interaction layer.
									</p>
									<p className="leading-relaxed text-on-surface-variant">
										We believe that the best way to protect data is to never collect it. Verra does not require account
										registration in the traditional sense. There are no cookies, no third-party trackers, and no shadow
										profiles. Your interaction with the protocol is validated through zero-knowledge proofs, proving
										eligibility without revealing identity.
									</p>
								</div>
							</div>
						</article>
					</div>
				</section>
			</main>

			<SiteFooter />
		</div>
	)
}
