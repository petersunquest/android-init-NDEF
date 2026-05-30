import { Loader2 } from 'lucide-react'
import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { posNativeBridge } from '@/bridge/nativeBridge'
import { PosScreenFooter, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import { hasPosWalletInIndexedDb } from '@/wallet/posWalletStorage'

const FIELD_CLASS =
	'mt-2 w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 text-mkt-onSurface outline-none focus:border-brand-blue'

/**
 * Init gate: terminal was configured before but IndexedDB has no plaintext mnemonic.
 * User must restore via @BeamioTag + Access Password (CoNET recover), then save locally.
 */
export function PosWalletRecoverPage() {
	const navigate = useNavigate()
	const { parentBeamioTag, registeredBeamioTag, markOnboardingComplete } = usePosSession()
	const [password, setPassword] = useState('')
	const [error, setError] = useState('')
	const [loading, setLoading] = useState(false)

	useEffect(() => {
		if (!parentBeamioTag || !registeredBeamioTag) {
			navigate('/', { replace: true })
			return
		}
		void (async () => {
			if (await hasPosWalletInIndexedDb()) {
				navigate('/permission', { replace: true })
			}
		})()
	}, [parentBeamioTag, registeredBeamioTag, navigate])

	async function onRestore() {
		setError('')
		if (!registeredBeamioTag) {
			setError('Terminal account is missing.')
			return
		}
		if (!password.trim()) {
			setError('Enter your access password')
			return
		}
		setLoading(true)
		const result = await posNativeBridge.restoreWallet({
			accountName: registeredBeamioTag,
			password,
		})
		setLoading(false)
		if (!result.ok || !result.address) {
			setError(result.error ?? 'Restore failed')
			return
		}
		markOnboardingComplete({
			wallet: result.address,
			accountName: registeredBeamioTag,
			parentTag: parentBeamioTag,
		})
		navigate('/permission', { replace: true })
	}

	return (
		<PosScreenShell>
			<PosScreenMain className="mx-auto w-full max-w-xl overflow-y-auto px-6 pt-[max(1rem,env(safe-area-inset-top))] pb-[max(1rem,env(safe-area-inset-bottom))]">
				<h1 className="text-2xl font-black">Unlock terminal wallet</h1>
				<p className="mt-2 text-sm text-mkt-onSurfaceVariant">
					Your terminal wallet needs to be restored from the network. Enter the access password for{' '}
					<span className="font-semibold text-mkt-onSurface">@{registeredBeamioTag}</span>
					{parentBeamioTag ? (
						<>
							{' '}
							(linked to <span className="font-semibold">@{parentBeamioTag}</span>)
						</>
					) : null}
					.
				</p>
				<label className="mt-6 block text-sm font-semibold">Access password</label>
				<input
					type="password"
					value={password}
					onChange={(e) => setPassword(e.target.value)}
					className={FIELD_CLASS}
					autoComplete="current-password"
					enterKeyHint="done"
				/>
				{error ? <p className="mt-3 text-sm text-red-600">{error}</p> : null}
			</PosScreenMain>
			<PosScreenFooter className="px-6">
				<button
					type="button"
					disabled={loading}
					onClick={() => void onRestore()}
					className="flex w-full items-center justify-center gap-2 rounded-2xl bg-brand-blue py-4 font-bold text-white disabled:opacity-50"
				>
					{loading ? <Loader2 className="h-5 w-5 animate-spin" /> : null}
					Restore and continue
				</button>
			</PosScreenFooter>
		</PosScreenShell>
	)
}
