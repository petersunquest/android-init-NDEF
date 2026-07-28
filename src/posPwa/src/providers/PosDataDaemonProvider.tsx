import {
	createContext,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useRef,
	useState,
	type ReactNode,
} from 'react'
import { usePosSession } from '@/providers/PosSessionProvider'

/** Wall-clock baseline for global POS data refresh (see beamio-interval-daemon-no-overlap.mdc). */
export const POS_DATA_DAEMON_INTERVAL_MS = 6000

interface PosDataDaemonContextValue {
	tickInFlight: boolean
	lastSuccessfulTickAt: number | null
	skippedTickCount: number
	/** Runs one refresh immediately; no-op while a tick is already in flight. */
	requestImmediateRefresh: () => Promise<void>
}

const PosDataDaemonContext = createContext<PosDataDaemonContextValue | null>(null)

/**
 * Single app-wide data feeder for Home dashboard and future live UI.
 * Pages must not start their own interval/setTimeout polling loops.
 */
export function PosDataDaemonProvider({ children }: { children: ReactNode }) {
	const { walletAddress, refreshHome, isBootLoading } = usePosSession()
	const [tickInFlight, setTickInFlight] = useState(false)
	const [lastSuccessfulTickAt, setLastSuccessfulTickAt] = useState<number | null>(null)
	const [skippedTickCount, setSkippedTickCount] = useState(0)
	const inFlightRef = useRef(false)

	const runTick = useCallback(async (): Promise<void> => {
		if (inFlightRef.current) return
		inFlightRef.current = true
		setTickInFlight(true)
		try {
			await refreshHome()
			setLastSuccessfulTickAt(Date.now())
		} finally {
			inFlightRef.current = false
			setTickInFlight(false)
		}
	}, [refreshHome])

	const requestImmediateRefresh = useCallback(async (): Promise<void> => {
		if (inFlightRef.current) return
		await runTick()
	}, [runTick])

	useEffect(() => {
		if (!walletAddress || isBootLoading) {
			setLastSuccessfulTickAt(null)
			setSkippedTickCount(0)
			return
		}

		let cancelled = false
		let timer: number | undefined

		const onAlarm = (): void => {
			if (cancelled) return
			if (inFlightRef.current) {
				setSkippedTickCount((n) => n + 1)
			} else {
				void runTick()
			}
			timer = window.setTimeout(onAlarm, POS_DATA_DAEMON_INTERVAL_MS)
		}

		void runTick()
		timer = window.setTimeout(onAlarm, POS_DATA_DAEMON_INTERVAL_MS)

		return () => {
			cancelled = true
			if (timer !== undefined) window.clearTimeout(timer)
		}
	}, [walletAddress, isBootLoading, runTick])

	const value = useMemo<PosDataDaemonContextValue>(
		() => ({
			tickInFlight,
			lastSuccessfulTickAt,
			skippedTickCount,
			requestImmediateRefresh,
		}),
		[tickInFlight, lastSuccessfulTickAt, skippedTickCount, requestImmediateRefresh],
	)

	return (
		<PosDataDaemonContext.Provider value={value}>{children}</PosDataDaemonContext.Provider>
	)
}

export function usePosDataDaemon(): PosDataDaemonContextValue {
	const ctx = useContext(PosDataDaemonContext)
	if (!ctx) {
		throw new Error('usePosDataDaemon must be used within PosDataDaemonProvider')
	}
	return ctx
}
