import { Loader2, RefreshCw, ShieldAlert, ShieldCheck } from 'lucide-react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { BeamioCapsule } from '@/components/BeamioCapsule'
import { PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import {
	clearPermissionAutoSent,
	loadPermissionAutoSent,
	savePermissionAutoSent,
	sendPosTerminalPermissionRequest,
} from '@/conet/posTerminalPermissionChat'
import { sleep } from '@/conet/crypto'
import { usePosDataDaemon } from '@/providers/PosDataDaemonProvider'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { TerminalProfile } from '@/types/pos'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'

const RESEND_COOLDOWN_MS = 120_000

export function ParentPermissionGatePage() {
	const navigate = useNavigate()
	const {
		walletAddress,
		parentBeamioTag,
		parentProfile,
		terminalProfile,
		registeredBeamioTag,
		showPermissionGate,
		adminAccessRevoked,
	} = usePosSession()
	const { tickInFlight, lastSuccessfulTickAt } = usePosDataDaemon()
	const [lastResendAt, setLastResendAt] = useState<number | null>(null)
	const [resendBusy, setResendBusy] = useState(false)
	const [statusMessage, setStatusMessage] = useState<string | null>(null)
	const [statusError, setStatusError] = useState(false)
	/** Tracks last wallet we auto-sent for; reset when admin revoked clears auto-sent flag. */
	const autoSendWalletRef = useRef<string | null>(null)

	const checking =
		showPermissionGate && (tickInFlight || lastSuccessfulTickAt === null)

	const selfTerminalProfile = useMemo((): TerminalProfile => {
		if (terminalProfile) return terminalProfile
		return {
			accountName: registeredBeamioTag ?? undefined,
			address: walletAddress ?? undefined,
		}
	}, [terminalProfile, registeredBeamioTag, walletAddress])

	const childBeamioTag = registeredBeamioTag ?? terminalProfile?.accountName ?? ''

	const dispatchPermissionRequest = useCallback(
		async (manualResend: boolean): Promise<boolean> => {
			if (!walletAddress || !parentBeamioTag) return false
			const pk = await getPosPrivateKeyHex()
			if (!pk) {
				setStatusError(true)
				setStatusMessage('Wallet signing key is unavailable in this session.')
				return false
			}
			if (manualResend) {
				setResendBusy(true)
			}
			setStatusError(false)
			setStatusMessage(
				manualResend
					? 'Sending approval request via CoNET chat…'
					: adminAccessRevoked
						? 'Access was removed. Re-registering CoNET chat keys and requesting POS permission again…'
						: 'Registering CoNET chat keys and sending approval request…',
			)
			const result = await sendPosTerminalPermissionRequest({
				walletPrivateKeyHex: pk,
				childEoa: walletAddress,
				childBeamioTag,
				parentBeamioTag,
				parentEoaHint: parentProfile?.address,
			})
			if (manualResend) {
				setResendBusy(false)
			}
			if (result.ok) {
				savePermissionAutoSent(walletAddress.toLowerCase())
				setStatusError(false)
				setStatusMessage(
					manualResend
						? 'Approval request sent again via CoNET chat.'
						: adminAccessRevoked
							? 'A new POS permission request was sent to your workspace parent via CoNET chat.'
							: 'A permission request was sent to your workspace parent via CoNET chat.',
				)
				return true
			}
			setStatusError(true)
			setStatusMessage(result.error)
			return false
		},
		[
			walletAddress,
			parentBeamioTag,
			childBeamioTag,
			parentProfile?.address,
			adminAccessRevoked,
		],
	)

	useEffect(() => {
		if (!walletAddress) {
			navigate('/', { replace: true })
		}
	}, [walletAddress, navigate])

	// When admin access is revoked, clear auto-sent so we re-request owner approval.
	useEffect(() => {
		if (!walletAddress || !adminAccessRevoked) return
		clearPermissionAutoSent(walletAddress.toLowerCase())
		autoSendWalletRef.current = null
	}, [walletAddress, adminAccessRevoked])

	useEffect(() => {
		if (!walletAddress || !parentBeamioTag) return
		const wl = walletAddress.toLowerCase()
		if (loadPermissionAutoSent(wl)) return
		if (autoSendWalletRef.current === wl) return

		let cancelled = false
		autoSendWalletRef.current = wl

		void (async () => {
			// iOS POS waits until `walletPrivateKeyHex != nil` before auto-send; native Keychain can lag after createWallet.
			let pk: string | null = null
			for (let i = 0; i < 20 && !cancelled; i++) {
				pk = await getPosPrivateKeyHex()
				if (pk) break
				await sleep(250)
			}
			if (cancelled) return
			if (!pk) {
				setStatusError(true)
				setStatusMessage('Wallet signing key is unavailable in this session.')
				autoSendWalletRef.current = null
				return
			}
			const ok = await dispatchPermissionRequest(false)
			if (!ok && !cancelled) {
				autoSendWalletRef.current = null
			}
		})()

		return () => {
			cancelled = true
		}
	}, [walletAddress, parentBeamioTag, adminAccessRevoked, dispatchPermissionRequest])

	async function onResend() {
		if (lastResendAt && Date.now() - lastResendAt < RESEND_COOLDOWN_MS) return
		setLastResendAt(Date.now())
		await dispatchPermissionRequest(true)
	}

	const cooldownLeft =
		lastResendAt != null
			? Math.max(0, Math.ceil((RESEND_COOLDOWN_MS - (Date.now() - lastResendAt)) / 1000))
			: 0

	return (
		<PosScreenShell bg="bg-mkt-bg">
			<PosScreenHeader className="border-b border-slate-200/70 bg-white/95 px-6 py-4">
				<BeamioCapsule
					profile={selfTerminalProfile}
					fallbackAddress={walletAddress}
					address={walletAddress}
					showAddressCapsule={Boolean(walletAddress)}
					tone="onLight"
					className="w-full max-w-md rounded-full border border-mkt-outlineVariant/30 bg-white py-1 pl-1 pr-3"
				/>
			</PosScreenHeader>

			<PosScreenMain className="mx-auto w-full max-w-md justify-center px-6">
				<div className="mx-auto flex h-16 w-16 items-center justify-center rounded-full bg-brand-blue/10 text-brand-blue">
					{checking ? (
						<Loader2 className="h-8 w-8 animate-spin" aria-hidden />
					) : adminAccessRevoked ? (
						<ShieldAlert className="h-8 w-8 text-amber-600" aria-hidden />
					) : (
						<ShieldCheck className="h-8 w-8" aria-hidden />
					)}
				</div>
				<h1 className="mt-6 text-center text-2xl font-black text-mkt-onSurface">
					{adminAccessRevoked
						? 'POS permission required again'
						: 'Waiting for workspace approval'}
				</h1>
				<p className="mt-3 text-center text-sm leading-relaxed text-mkt-onSurfaceVariant">
					{adminAccessRevoked ? (
						<>
							This terminal is no longer an admin on the merchant program card for{' '}
							<span className="font-semibold text-mkt-onSurface">@{parentBeamioTag}</span>.
							Request POS permission from the workspace owner again before using Home.
						</>
					) : (
						<>
							Your terminal wallet was created. The merchant workspace{' '}
							<span className="font-semibold text-mkt-onSurface">@{parentBeamioTag}</span> must
							approve this device before you can use Home.
						</>
					)}
				</p>
				<p className="mt-4 text-center text-xs text-mkt-onSurfaceVariant">
					{adminAccessRevoked
						? 'A new CoNET chat permission request is sent automatically. Global refresh checks admin status every few seconds. You can resend if needed.'
						: 'A secure CoNET chat message was sent to the workspace owner. Global data refresh checks approval every few seconds. You can resend if needed.'}
				</p>

				{statusMessage ? (
					<p
						className={`mt-4 text-center text-sm ${statusError ? 'text-amber-700' : 'text-emerald-700'}`}
						role="status"
					>
						{statusMessage}
					</p>
				) : null}

				<button
					type="button"
					disabled={resendBusy || cooldownLeft > 0}
					onClick={() => void onResend()}
					className="mt-8 flex w-full items-center justify-center gap-2 rounded-2xl border border-brand-blue/30 bg-white py-3.5 text-sm font-bold text-brand-blue disabled:opacity-50"
				>
					{resendBusy ? (
						<Loader2 className="h-4 w-4 animate-spin" />
					) : (
						<RefreshCw className="h-4 w-4" />
					)}
					{cooldownLeft > 0 ? `Resend in ${cooldownLeft}s` : 'Resend approval request'}
				</button>

				<button
					type="button"
					onClick={() => navigate('/', { replace: true })}
					className="mt-4 text-center text-sm font-semibold text-mkt-onSurfaceVariant underline-offset-2 hover:underline"
				>
					Change workspace parent
				</button>
			</PosScreenMain>
		</PosScreenShell>
	)
}
