import { useCallback, useEffect, useState } from 'react'
import {
	isEmbeddedPwaOtaSupported,
	readEmbeddedPwaPendingVersion,
	readEmbeddedPwaVersion,
	requestEmbeddedPwaUpdateApply,
	subscribeApplyEmbeddedPwaUpdateResult,
	subscribeEmbeddedPwaUpdateAvailable,
} from '../utils/cashTreesEmbeddedPwaUpdate'

/**
 * Native-shell banner (iOS / Android embedded POS PWA). Renders nothing in browser.
 */
export function EmbeddedPwaUpdateBanner(): React.ReactElement | null {
	const [pendingVer, setPendingVer] = useState('')
	const [currentVer, setCurrentVer] = useState('')
	const [applying, setApplying] = useState(false)
	const [error, setError] = useState('')

	useEffect(() => {
		if (!isEmbeddedPwaOtaSupported()) return undefined

		setCurrentVer(readEmbeddedPwaVersion())
		const initialPending = readEmbeddedPwaPendingVersion()
		if (initialPending) setPendingVer(initialPending)

		const offAvailable = subscribeEmbeddedPwaUpdateAvailable(({ currentVer: cur, pendingVer: pending }) => {
			setCurrentVer(cur)
			setPendingVer(pending)
			setError('')
		})

		const offApply = subscribeApplyEmbeddedPwaUpdateResult(({ ok, error: applyError }) => {
			setApplying(false)
			if (!ok) {
				setError(applyError || 'Update failed')
				return
			}
			setPendingVer('')
			setError('')
		})

		return () => {
			offAvailable()
			offApply()
		}
	}, [])

	const onRestart = useCallback(() => {
		if (applying || !pendingVer) return
		setApplying(true)
		setError('')
		requestEmbeddedPwaUpdateApply()
	}, [applying, pendingVer])

	if (!isEmbeddedPwaOtaSupported() || !pendingVer) return null

	return (
		<div
			className="fixed inset-x-0 top-0 z-[9999] flex items-center justify-between gap-3 border-b border-white/10 bg-[#000414]/95 px-4 py-2 text-sm text-white backdrop-blur-md"
			style={{ paddingTop: 'max(0.5rem, env(safe-area-inset-top))' }}
			role="status"
		>
			<div className="min-w-0 flex-1">
				<p className="truncate font-medium">Update ready ({pendingVer})</p>
				{currentVer ? (
					<p className="truncate text-xs text-white/70">Current: {currentVer}</p>
				) : null}
				{error ? <p className="truncate text-xs text-amber-300">{error}</p> : null}
			</div>
			<button
				type="button"
				className="shrink-0 rounded-full bg-white px-4 py-1.5 text-sm font-semibold text-[#000414] disabled:opacity-50"
				disabled={applying}
				onClick={onRestart}
			>
				{applying ? 'Restarting…' : 'Restart'}
			</button>
		</div>
	)
}
