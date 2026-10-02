import { useState, type CSSProperties } from 'react'
import type { MembershipKycFormPolicy } from '@/utils/membershipKyc'
import { saveMembershipKycAndLink } from '@/utils/membershipKyc'

type Props = {
	policy: MembershipKycFormPolicy
	cardAddress: string
	privateKey: string
	subjectWallet: string
	signerKind: 'wallet' | 'admin'
	onClose: () => void
	onLinked: () => void
}

export function BecomeMemberSheet({
	policy,
	cardAddress,
	privateKey,
	subjectWallet,
	signerKind,
	onClose,
	onLinked,
}: Props) {
	const [fullName, setFullName] = useState('')
	const [phone, setPhone] = useState('')
	const [email, setEmail] = useState('')
	const [consent, setConsent] = useState(false)
	const [terms, setTerms] = useState(false)
	const [emailOffers, setEmailOffers] = useState(false)
	const [smsOffers, setSmsOffers] = useState(false)
	const [busy, setBusy] = useState(false)
	const [error, setError] = useState('')
	const merchant = policy.merchantName || 'This merchant'

	const missing =
		(policy.fields.name === 'required' && !fullName.trim()) ||
		(policy.fields.phone === 'required' && !phone.trim()) ||
		(policy.fields.email === 'required' && !email.trim()) ||
		!consent ||
		!terms

	const continueNext = async () => {
		if (busy || missing) return
		setBusy(true)
		setError('')
		try {
			await saveMembershipKycAndLink({
				cardAddress,
				privateKey,
				fullName,
				phone,
				email,
				emailOffers,
				smsOffers,
				signerKind,
				subjectWallet,
			})
			onLinked()
		} catch (err) {
			setError(err instanceof Error ? err.message : 'Could not save membership details.')
			setBusy(false)
		}
	}

	const phoneOff = policy.fields.phone === 'off'
	const emailOff = policy.fields.email === 'off'
	const detailTail =
		phoneOff && emailOff
			? '.'
			: policy.fields.phone !== 'required' && policy.fields.email !== 'required'
				? '; phone and email are optional.'
				: '; phone and email follow the merchant’s request.'
	const brandColor = policy.brandColor || '#6d5ce7'
	const themeStyle = {
		'--membership-brand': brandColor,
		'--membership-brand-soft': `color-mix(in srgb, ${brandColor} 10%, white)`,
		'--membership-brand-border': `color-mix(in srgb, ${brandColor} 24%, white)`,
		'--membership-brand-muted': `color-mix(in srgb, ${brandColor} 68%, #64748b)`,
	} as CSSProperties

	return (
		<div
			className="fixed inset-0 z-[320] flex justify-center overflow-y-auto bg-[color:var(--membership-brand-soft)] px-4 py-6"
			style={themeStyle}
		>
			<div className="mx-auto w-full max-w-lg pb-8 pt-1">
				<button
					type="button"
					aria-label="Back"
					tabIndex={-1}
					onClick={onClose}
					className="mb-5 flex h-10 w-10 items-center justify-center rounded-full border border-black/5 bg-white text-[#2c2f31] shadow-[0_2px_10px_rgba(15,23,42,0.12)]"
				>
					<svg viewBox="0 0 24 24" className="h-4 w-4" aria-hidden>
						<path d="M14.5 6.5 9 12l5.5 5.5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
					</svg>
				</button>
				<h1 className="text-[32px] font-semibold tracking-[-0.03em] text-[#17151f]">Become a member</h1>
				<p className="mt-2 max-w-[34rem] text-[15px] leading-6 text-slate-600">
					Complete your member details and accept the terms to continue.
				</p>
				{policy.offerValue ? (
					<div className="mt-6 rounded-2xl border border-[color:var(--membership-brand-border)] bg-white px-4 py-4 shadow-[0_8px_24px_rgba(72,55,120,0.06)]">
						<div className="flex items-center gap-2">
							<span className="flex h-9 w-9 items-center justify-center rounded-lg bg-[color:var(--membership-brand-soft)] text-[color:var(--membership-brand)]" aria-hidden>
								<svg viewBox="0 0 24 24" className="h-5 w-5">
									<path d="M4 10.5 12 4l8 6.5V20a1 1 0 0 1-1 1h-5v-6H10v6H5a1 1 0 0 1-1-1v-9.5Z" fill="none" stroke="currentColor" strokeWidth="1.6" />
								</svg>
							</span>
							<div>
								<p className="text-[15px] font-semibold text-[color:var(--membership-brand)]">{merchant}</p>
								<p className="text-[12px] text-slate-500">{policy.offerLabel}</p>
							</div>
						</div>
						<div className="mt-4 grid grid-cols-2 gap-4 border-t border-slate-100 pt-3">
							<div>
								<p className="text-[12px] text-slate-500">Membership fee</p>
								<p className="mt-1 text-[16px] font-semibold text-slate-900">{policy.offerValue}</p>
							</div>
							<div className="text-right">
								<p className="text-[12px] text-slate-500">Valid for</p>
								<p className="mt-1 text-[16px] font-semibold text-slate-900">{policy.offerReward}</p>
							</div>
						</div>
					</div>
				) : null}
				<div className="mt-7 flex items-start gap-3">
					<span className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-[color:var(--membership-brand-soft)] text-[color:var(--membership-brand)]" aria-hidden>
						<svg viewBox="0 0 24 24" className="h-4 w-4" fill="none">
							<rect x="5" y="10" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.7" />
							<path d="M8 10V7a4 4 0 0 1 8 0v3" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
						</svg>
					</span>
					<p className="text-[13px] leading-5 text-slate-600">
						{merchant} collects these details to create your profile and provide membership services. Your
						name identifies your member profile{detailTail} Your wallet remains your member ID.
					</p>
				</div>
				{policy.fields.name !== 'off' ? (
					<label className="mt-6 block text-[14px] font-semibold text-slate-900">
						Full name {policy.fields.name === 'required' ? <span className="text-[color:var(--membership-brand)]">*</span> : <span className="font-normal text-slate-500">(optional)</span>}
						<input
							value={fullName}
							onChange={(event) => setFullName(event.target.value)}
							placeholder="Your name"
							className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3.5 py-3 text-[15px] font-normal outline-none focus:border-[color:var(--membership-brand)] focus:ring-2 focus:ring-[color:var(--membership-brand-soft)]"
						/>
					</label>
				) : null}
				{policy.fields.phone !== 'off' ? (
					<label className="mt-4 block text-[14px] font-semibold text-slate-900">
						Phone number {policy.fields.phone === 'required' ? <span className="text-[color:var(--membership-brand)]">*</span> : <span className="font-normal text-slate-500">(optional)</span>}
						<input
							value={phone}
							onChange={(event) => setPhone(event.target.value)}
							placeholder="+1 604 555 0123"
							inputMode="tel"
							className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3.5 py-3 text-[15px] font-normal outline-none focus:border-[color:var(--membership-brand)] focus:ring-2 focus:ring-[color:var(--membership-brand-soft)]"
						/>
					</label>
				) : null}
				{policy.fields.email !== 'off' ? (
					<label className="mt-4 block text-[14px] font-semibold text-slate-900">
						Email {policy.fields.email === 'required' ? <span className="text-[color:var(--membership-brand)]">*</span> : <span className="font-normal text-slate-500">(optional)</span>}
						<input
							value={email}
							onChange={(event) => setEmail(event.target.value)}
							placeholder="you@example.com"
							inputMode="email"
							className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3.5 py-3 text-[15px] font-normal outline-none focus:border-[color:var(--membership-brand)] focus:ring-2 focus:ring-[color:var(--membership-brand-soft)]"
						/>
					</label>
				) : null}
				<label className="mt-6 flex items-start gap-2 text-[13px] leading-5 text-slate-600">
					<input type="checkbox" checked={consent} onChange={(event) => setConsent(event.target.checked)} />
					<span>
						I consent to {merchant} processing the information I provide for the purposes described in the{' '}
						<span className="font-medium text-[color:var(--membership-brand)]">{merchant} Privacy Notice</span>.
					</span>
				</label>
				<label className="mt-3 flex items-start gap-2 text-[13px] leading-5 text-slate-600">
					<input type="checkbox" checked={terms} onChange={(event) => setTerms(event.target.checked)} />
					<span>
						I have read and agree to the <span className="font-medium text-[color:var(--membership-brand)]">{merchant} Membership Terms</span>.
					</span>
				</label>
				<label className="mt-3 flex items-start gap-2 text-[13px] leading-5 text-slate-600">
					<input type="checkbox" checked={emailOffers} onChange={(event) => setEmailOffers(event.target.checked)} />
					<span>Send me offers and updates from {merchant} by email. (Optional. Unsubscribe anytime.)</span>
				</label>
				<label className="mt-3 flex items-start gap-2 text-[13px] leading-5 text-slate-600">
					<input type="checkbox" checked={smsOffers} onChange={(event) => setSmsOffers(event.target.checked)} />
					<span>Send me offers and updates from {merchant} by SMS. (Optional. Unsubscribe anytime.)</span>
				</label>
				<p className="mt-4 text-[12px] text-[#6b7076]">Sent by {merchant} · Merchant contact details</p>
				{error ? (
					<p role="alert" className="mt-3 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-[13px] text-rose-700">
						{error}
					</p>
				) : null}
				<button
					type="button"
					disabled={missing || busy}
					onClick={() => void continueNext()}
					aria-busy={busy}
					className="mt-5 w-full rounded-xl bg-[color:var(--membership-brand)] py-3.5 text-[16px] font-semibold text-white shadow-[0_8px_18px_rgba(72,55,120,0.18)] transition hover:brightness-95 disabled:cursor-not-allowed disabled:opacity-50"
				>
					{busy ? (
						<span className="inline-flex items-center justify-center gap-2">
							<svg className="h-4 w-4 animate-spin" viewBox="0 0 24 24" fill="none" aria-hidden>
								<circle cx="12" cy="12" r="9" stroke="currentColor" strokeOpacity="0.35" strokeWidth="3" />
								<path d="M21 12a9 9 0 0 1-9 9" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
							</svg>
							Saving…
						</span>
					) : 'Continue to payment →'}
				</button>
				<p className="mt-3 text-center text-[12px] leading-5 text-slate-500">
					Review your payment next. You will not be charged yet.
					<br />
					Powered by Beamio · Technology & tools
				</p>
			</div>
		</div>
	)
}
