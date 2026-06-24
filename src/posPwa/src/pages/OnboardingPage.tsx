import { Eye, EyeOff, Loader2 } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { isBeamioAccountNameAvailable, probeBeamioTagRegistration } from '@/api/beamioApi'
import { posNativeBridge } from '@/bridge/nativeBridge'
import {
	BEAMIO_CIRCULAR_BACK_ROW_CLASS,
	BeamioCircularBackButton,
} from '@/components/BeamioCircularBackButton'
import { PosScreenFooter, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import { localValidateBeamioTag, normalizeBeamioTagInput, passwordRules } from '@/utils/beamioTagRules'
import { resolveFirstAvailablePosTerminalTag } from '@/utils/posTerminalTag'

const ONBOARDING_FIELD_CLASS =
	'mt-2 w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 text-mkt-onSurface outline-none focus:border-brand-blue'

type TagStatus = 'idle' | 'checking' | 'valid' | 'invalid'

export function OnboardingPage() {
	const navigate = useNavigate()
	const { parentBeamioTag, markOnboardingComplete } = usePosSession()
	const [beamioTag, setBeamioTag] = useState('')
	const [password, setPassword] = useState('')
	const [confirmPassword, setConfirmPassword] = useState('')
	const [showPassword, setShowPassword] = useState(false)
	const [tagStatus, setTagStatus] = useState<TagStatus>('idle')
	const [tagError, setTagError] = useState('')
	const [submitError, setSubmitError] = useState('')
	const [isSubmitting, setIsSubmitting] = useState(false)
	const [showRestore, setShowRestore] = useState(false)
	const [restoreTag, setRestoreTag] = useState('')
	const [restorePassword, setRestorePassword] = useState('')
	const [restoreError, setRestoreError] = useState('')
	const [restoreLoading, setRestoreLoading] = useState(false)
	const lastChecked = useRef('')
	const debounceRef = useRef<number | null>(null)
	const accessPasswordRef = useRef<HTMLInputElement>(null)
	const continueInFlightRef = useRef(false)

	useEffect(() => {
		if (!parentBeamioTag) {
			navigate('/', { replace: true })
			return
		}
		void (async () => {
			const suggested = await resolveFirstAvailablePosTerminalTag(
				parentBeamioTag,
				isBeamioAccountNameAvailable,
			)
			if (!suggested) return
			const probe = await probeBeamioTagRegistration(suggested)
			if (!probe.ok) return
			setBeamioTag(suggested)
			lastChecked.current = suggested
			setTagStatus('valid')
			setTagError('')
		})()
	}, [parentBeamioTag, navigate])

	useEffect(() => {
		if (showRestore || !parentBeamioTag) return
		const frame = window.requestAnimationFrame(() => {
			accessPasswordRef.current?.focus()
		})
		return () => window.cancelAnimationFrame(frame)
	}, [showRestore, parentBeamioTag])

	const normalizedTag = normalizeBeamioTagInput(beamioTag)
	const localTag = localValidateBeamioTag(beamioTag)
	const rules = passwordRules(password)
	const passwordsMatch = password.length > 0 && password === confirmPassword
	// Allow Continue when tag passes local rules; remote availability is re-checked in onContinue.
	// Auto-suggested tags may stay `idle` until blur/debounce even though they are available.
	const canSubmit =
		localTag.ok &&
		tagStatus === 'valid' &&
		rules.all &&
		passwordsMatch &&
		!isSubmitting

	async function validateTagNow(): Promise<boolean> {
		const loc = localValidateBeamioTag(beamioTag)
		setTagError('')
		if (!loc.ok) {
			if (loc.value) {
				setTagStatus('invalid')
				setTagError(loc.message)
			} else {
				setTagStatus('idle')
			}
			return false
		}
		lastChecked.current = loc.value
		setTagStatus('checking')
		const probe = await probeBeamioTagRegistration(loc.value)
		if (probe.ok) {
			setTagStatus('valid')
			setTagError('')
			return true
		}
		if (probe.reason === 'taken') {
			setTagStatus('invalid')
			setTagError(`@${loc.value} is already taken`)
			return false
		}
		setTagStatus('invalid')
		setTagError('Network error. Try again.')
		return false
	}

	function scheduleTagCheck(tagRaw?: string) {
		if (debounceRef.current) window.clearTimeout(debounceRef.current)
		const trimmed = normalizeBeamioTagInput(tagRaw ?? beamioTag)
		if (trimmed.length <= 2) return
		debounceRef.current = window.setTimeout(() => {
			void validateTagNow()
		}, 600)
	}

	async function onContinue() {
		if (continueInFlightRef.current) return
		continueInFlightRef.current = true
		setIsSubmitting(true)
		setSubmitError('')
		try {
			const ok = await validateTagNow()
			if (!ok) return
			if (!rules.all || !passwordsMatch) return
			const result = await posNativeBridge.createWallet({
				accountName: normalizedTag,
				password,
				parentBeamioTag,
			})
			if (!result.ok || !result.address) {
				setSubmitError(result.error ?? 'Registration failed')
				return
			}
			markOnboardingComplete({
				wallet: result.address,
				accountName: normalizedTag,
				parentTag: parentBeamioTag,
			})
			navigate('/permission', { replace: true })
		} finally {
			continueInFlightRef.current = false
			setIsSubmitting(false)
		}
	}

	async function onRestore() {
		setRestoreError('')
		const loc = localValidateBeamioTag(restoreTag)
		if (!loc.ok) {
			setRestoreError(loc.message)
			return
		}
		if (!restorePassword) {
			setRestoreError('Enter your access password')
			return
		}
		setRestoreLoading(true)
		const result = await posNativeBridge.restoreWallet({
			accountName: loc.value,
			password: restorePassword,
		})
		setRestoreLoading(false)
		if (!result.ok || !result.address) {
			setRestoreError(result.error ?? 'Restore failed')
			return
		}
		markOnboardingComplete({
			wallet: result.address,
			accountName: loc.value,
			parentTag: parentBeamioTag,
		})
		navigate('/permission', { replace: true })
	}

	if (showRestore) {
		return (
			<PosScreenShell>
				<PosScreenMain className="mx-auto w-full max-w-xl overflow-y-auto px-6 pt-[max(1rem,env(safe-area-inset-top))] pb-[max(1rem,env(safe-area-inset-bottom))]">
				<div className={BEAMIO_CIRCULAR_BACK_ROW_CLASS}>
					<BeamioCircularBackButton
						onClick={() => setShowRestore(false)}
						className="absolute left-0 top-0"
					/>
				</div>
				<h1 className="text-2xl font-black">Restore workspace</h1>
				<p className="mt-2 text-sm text-mkt-onSurfaceVariant">
					Enter your @BeamioTag and access password to restore this terminal.
				</p>
				<label className="mt-6 block text-sm font-semibold">@BeamioTag</label>
				<input
					value={restoreTag}
					onChange={(e) => setRestoreTag(e.target.value.replace(/^@+/, ''))}
					className={ONBOARDING_FIELD_CLASS}
					autoComplete="username"
				/>
				<label className="mt-4 block text-sm font-semibold">Access password</label>
				<input
					type="password"
					value={restorePassword}
					onChange={(e) => setRestorePassword(e.target.value)}
					className={ONBOARDING_FIELD_CLASS}
					autoComplete="current-password"
				/>
				{restoreError ? (
					<p className="mt-3 text-sm text-red-600">{restoreError}</p>
				) : null}
				<button
					type="button"
					disabled={restoreLoading}
					onClick={() => void onRestore()}
					className="mt-6 flex w-full items-center justify-center gap-2 rounded-2xl bg-brand-blue py-4 font-bold text-white disabled:opacity-50"
				>
					{restoreLoading ? <Loader2 className="h-5 w-5 animate-spin" /> : null}
					Restore
				</button>
				</PosScreenMain>
			</PosScreenShell>
		)
	}

	return (
		<PosScreenShell>
			<PosScreenMain className="mx-auto w-full max-w-xl min-h-0">
				<div className="flex min-h-0 flex-1 flex-col overflow-hidden px-6 pt-[max(1rem,env(safe-area-inset-top))]">
					<div className={BEAMIO_CIRCULAR_BACK_ROW_CLASS}>
						<BeamioCircularBackButton
							onClick={() => navigate('/')}
							className="absolute left-0 top-0"
						/>
					</div>
					<div className="min-h-0 flex-1 overflow-y-auto overscroll-contain pb-3">
				<p className="text-xs font-bold uppercase tracking-widest text-brand-blue">Step 1 of 2</p>
				<h1 className="mt-2 text-3xl font-black">Wallet setup</h1>
				<p className="mt-2 text-sm text-mkt-onSurfaceVariant">
					Create your terminal @BeamioTag linked to{' '}
					<span className="font-semibold text-mkt-onSurface">@{parentBeamioTag}</span>.
				</p>

				<form
					id="pos-onboarding-form"
					className="mt-8"
					onSubmit={(e) => {
						e.preventDefault()
						if (canSubmit) void onContinue()
					}}
				>
					<label htmlFor="pos-terminal-beamio-tag" className="block text-sm font-semibold">
						Terminal @BeamioTag
					</label>
					<input
						id="pos-terminal-beamio-tag"
						tabIndex={1}
						enterKeyHint="next"
						value={beamioTag}
						onChange={(e) => {
							const next = e.target.value.replace(/^@+/, '')
							setBeamioTag(next)
							const loc = localValidateBeamioTag(next)
							if (!loc.ok || loc.value !== lastChecked.current) {
								if (tagStatus === 'valid') setTagStatus('idle')
							}
							scheduleTagCheck(next)
						}}
						onBlur={() => void validateTagNow()}
						className={ONBOARDING_FIELD_CLASS}
						autoComplete="off"
					/>
					{tagStatus === 'checking' ? (
						<p className="mt-2 text-xs text-mkt-onSurfaceVariant">Checking availability…</p>
					) : null}
					{tagError ? <p className="mt-2 text-xs text-red-600">{tagError}</p> : null}
					{tagStatus === 'valid' ? (
						<p className="mt-2 text-xs text-emerald-600">Handle is available</p>
					) : null}

					<label htmlFor="pos-access-password" className="mt-6 block text-sm font-semibold">
						Access password
					</label>
					<div className="relative mt-2">
						<input
							ref={accessPasswordRef}
							id="pos-access-password"
							tabIndex={2}
							enterKeyHint="next"
							type={showPassword ? 'text' : 'password'}
							value={password}
							onChange={(e) => setPassword(e.target.value)}
							className="w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 pr-12 text-mkt-onSurface outline-none focus:border-brand-blue"
							autoComplete="new-password"
						/>
						<button
							type="button"
							tabIndex={-1}
							className="absolute right-3 top-1/2 -translate-y-1/2 text-mkt-onSurfaceVariant"
							onClick={() => setShowPassword((v) => !v)}
							aria-label={showPassword ? 'Hide password' : 'Show password'}
						>
							{showPassword ? <EyeOff className="h-5 w-5" /> : <Eye className="h-5 w-5" />}
						</button>
					</div>
					<ul className="mt-2 space-y-1 text-xs text-mkt-onSurfaceVariant">
						<li className={rules.len8 ? 'text-emerald-600' : ''}>At least 8 characters</li>
						<li className={rules.mixed ? 'text-emerald-600' : ''}>Upper and lower case letters</li>
						<li className={rules.numbers ? 'text-emerald-600' : ''}>At least one number</li>
					</ul>

					<label htmlFor="pos-confirm-password" className="mt-4 block text-sm font-semibold">
						Confirm password
					</label>
					<input
						id="pos-confirm-password"
						tabIndex={3}
						enterKeyHint="done"
						type="password"
						value={confirmPassword}
						onChange={(e) => setConfirmPassword(e.target.value)}
						className={ONBOARDING_FIELD_CLASS}
						autoComplete="new-password"
					/>
					{confirmPassword && !passwordsMatch ? (
						<p className="mt-2 text-xs text-red-600">Passwords do not match</p>
					) : null}

					{submitError ? <p className="mt-4 text-sm text-red-600">{submitError}</p> : null}
				</form>

				<button
					type="button"
					tabIndex={5}
					className="mt-6 text-sm font-semibold text-brand-blue"
					onClick={() => setShowRestore(true)}
				>
					Restore existing terminal
				</button>
					</div>
				</div>
			</PosScreenMain>

			<PosScreenFooter>
				<button
					type="submit"
					form="pos-onboarding-form"
					tabIndex={4}
					disabled={!canSubmit}
					className="flex w-full items-center justify-center gap-2 rounded-2xl bg-brand-blue py-4 text-base font-bold text-white disabled:cursor-not-allowed disabled:opacity-40"
				>
					{isSubmitting ? <Loader2 className="h-5 w-5 animate-spin" /> : null}
					Continue
				</button>
			</PosScreenFooter>
		</PosScreenShell>
	)
}
