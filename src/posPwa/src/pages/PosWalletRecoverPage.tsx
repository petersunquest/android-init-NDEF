import { Loader2 } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Navigate, useNavigate } from 'react-router-dom'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import { hasPosWalletInIndexedDb } from '@/wallet/posWalletStorage'
import { unlockPosWalletFromIndexedDbMnemonic } from '@/wallet/posWalletService'

/**
 * Legacy `/recover` route.
 * IndexedDB mnemonic → unlock silently.
 * No local mnemonic → onboarding workflow (Welcome), never Access Password here.
 */
export function PosWalletRecoverPage() {
	const navigate = useNavigate()
	const { resumeBootAfterLocalWalletReady } = usePosSession()
	const [redirectOnboarding, setRedirectOnboarding] = useState(false)
	const [error, setError] = useState('')

	useEffect(() => {
		let cancelled = false
		void (async () => {
			try {
				if (await hasPosWalletInIndexedDb()) {
					const unlocked = await unlockPosWalletFromIndexedDbMnemonic()
					if (cancelled) return
					if (unlocked.ok) {
						const resumed = await resumeBootAfterLocalWalletReady()
						if (cancelled) return
						if (resumed) return
						setError('Local wallet opened but home could not load. Try again.')
						return
					}
				}
				if (!cancelled) setRedirectOnboarding(true)
			} catch {
				if (!cancelled) setRedirectOnboarding(true)
			}
		})()
		return () => {
			cancelled = true
		}
	}, [resumeBootAfterLocalWalletReady])

	if (redirectOnboarding) {
		return <Navigate to="/" replace />
	}

	return (
		<PosScreenShell>
			<PosScreenMain className="mx-auto flex w-full max-w-xl flex-col items-center justify-center px-6 pt-[max(1rem,env(safe-area-inset-top))] pb-[max(1rem,env(safe-area-inset-bottom))]">
				<Loader2 className="h-8 w-8 animate-spin text-brand-blue" aria-hidden />
				<p className="mt-4 text-center text-sm text-mkt-onSurfaceVariant">
					{error
						? error
						: 'Opening terminal wallet from local storage…'}
				</p>
				{error ? (
					<button
						type="button"
						className="mt-4 text-sm font-semibold text-brand-blue"
						onClick={() => navigate('/', { replace: true })}
					>
						Continue to setup
					</button>
				) : null}
			</PosScreenMain>
		</PosScreenShell>
	)
}
