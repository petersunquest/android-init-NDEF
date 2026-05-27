import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchPosLedger } from '@/api/beamioApi'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { PosLedgerSnapshot } from '@/utils/posLedgerMetrics'
import { posHomeTrustedCache } from '@/utils/trustedCache'

/** iOS `openPosTransactionsScreen` + `refreshPosLedgerTrustedOnly` — local-first, trusted-only writes. */
export function usePosLedger() {
	const { walletAddress, merchantInfraCard } = usePosSession()
	const [snapshot, setSnapshot] = useState<PosLedgerSnapshot | null>(null)
	const [loading, setLoading] = useState(false)
	const [refreshing, setRefreshing] = useState(false)
	const [lastError, setLastError] = useState<string | null>(null)
	const refreshGen = useRef(0)
	const snapshotRef = useRef<PosLedgerSnapshot | null>(null)
	snapshotRef.current = snapshot

	const wallet = walletAddress?.trim() ?? ''
	const infra = merchantInfraCard?.trim() ?? ''

	useEffect(() => {
		if (!wallet || !infra) return
		const cached = posHomeTrustedCache.loadPosLedger(wallet, infra)
		if (cached) setSnapshot(cached)
	}, [wallet, infra])

	const refreshTrustedOnly = useCallback(async () => {
		if (!wallet || !infra) return
		const gen = ++refreshGen.current
		const hadCached = snapshotRef.current != null
		if (hadCached) {
			setRefreshing(true)
			setLoading(false)
		} else {
			setLoading(true)
			setRefreshing(false)
		}

		const snap = await fetchPosLedger(wallet, infra)
		if (gen !== refreshGen.current) return

		if (snap) {
			setSnapshot(snap)
			setLastError(null)
			posHomeTrustedCache.savePosLedger(snap, wallet, infra)
		} else {
			setLastError('Could not refresh transactions. Showing last known list.')
		}
		setLoading(false)
		setRefreshing(false)
	}, [wallet, infra])

	useEffect(() => {
		if (!wallet || !infra) return
		void refreshTrustedOnly()
	}, [wallet, infra, refreshTrustedOnly])

	return {
		snapshot,
		loading,
		refreshing,
		lastError,
		refreshTrustedOnly,
	}
}
