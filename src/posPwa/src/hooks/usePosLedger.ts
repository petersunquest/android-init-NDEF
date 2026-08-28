import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchPosLedger } from '@/api/beamioApi'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { PosLedgerSnapshot } from '@/utils/posLedgerMetrics'
import { posHomeTrustedCache } from '@/utils/trustedCache'

/** iOS `openPosTransactionsScreen` + `refreshPosLedgerTrustedOnly` — local-first, trusted-only writes. */
export function usePosLedger() {
	const { walletAddress, merchantInfraCard, activeUpperEoa } = usePosSession()
	const [snapshot, setSnapshot] = useState<PosLedgerSnapshot | null>(null)
	const [loading, setLoading] = useState(false)
	const [refreshing, setRefreshing] = useState(false)
	const [lastError, setLastError] = useState<string | null>(null)
	const refreshGen = useRef(0)
	const snapshotRef = useRef<PosLedgerSnapshot | null>(null)
	snapshotRef.current = snapshot

	const wallet = walletAddress?.trim() ?? ''
	const infra = merchantInfraCard?.trim() ?? ''
	const upper = activeUpperEoa?.trim() ?? ''

	/*
	 * Partition key = terminal wallet + upperAdmin EOA + infra card.
	 * On switch: always replace memory with this partition's local ledger (or null).
	 * Never leave the previous upper's Transactions on screen.
	 */
	useEffect(() => {
		if (!wallet || !infra || !upper) {
			refreshGen.current += 1
			setSnapshot(null)
			setLastError(null)
			setLoading(false)
			setRefreshing(false)
			return
		}
		/* Invalidate in-flight fetch from the previous partition. */
		const gen = ++refreshGen.current
		const cached = posHomeTrustedCache.loadPosLedger(wallet, upper, infra)
		setSnapshot(cached)
		setLastError(null)

		const run = async () => {
			const hadCached = cached != null
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
				posHomeTrustedCache.savePosLedger(snap, wallet, upper, infra)
			} else {
				setLastError('Could not refresh transactions. Showing last known list.')
			}
			setLoading(false)
			setRefreshing(false)
		}
		void run()
	}, [wallet, infra, upper])

	const refreshTrustedOnly = useCallback(async () => {
		if (!wallet || !infra || !upper) return
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
			posHomeTrustedCache.savePosLedger(snap, wallet, upper, infra)
		} else {
			setLastError('Could not refresh transactions. Showing last known list.')
		}
		setLoading(false)
		setRefreshing(false)
	}, [wallet, infra, upper])

	return {
		snapshot,
		loading,
		refreshing,
		lastError,
		refreshTrustedOnly,
	}
}
