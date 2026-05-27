import { useEffect, useRef } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { listenNativeBridge, posNativeBridge } from '@/bridge/nativeBridge'
import { PosFlowLoadingShell } from '@/components/PosFlowLoadingShell'
import {
	NATIVE_ACTION_LOADING,
	POS_HOME_ROUTES,
	parseNativeActionParam,
} from '@/utils/posHomeActionRoutes'

/**
 * Native Home actions: leave /home immediately, show loading, then hand off to native shell.
 * See `beamio-pos-pwa-home-action-flow.mdc`.
 */
export function NativeActionPage() {
	const { action: actionParam } = useParams<{ action: string }>()
	const navigate = useNavigate()
	const launchedRef = useRef(false)

	const action = parseNativeActionParam(actionParam)
	const loadingCopy = action ? NATIVE_ACTION_LOADING[action] : null

	useEffect(() => {
		if (action) return
		navigate(POS_HOME_ROUTES.home, { replace: true })
	}, [action, navigate])

	useEffect(() => {
		if (!action || launchedRef.current) return
		launchedRef.current = true
		posNativeBridge.navigateNative(action)
	}, [action])

	useEffect(() => {
		if (!action) return
		return listenNativeBridge((detail) => {
			const d = detail as { type?: string } | null
			if (d?.type === 'nativeFlowComplete' || d?.type === 'navigateHome') {
				navigate(POS_HOME_ROUTES.home, { replace: true })
			}
		})
	}, [action, navigate])

	if (!action || !loadingCopy) {
		return (
			<PosFlowLoadingShell title="Unavailable" subtitle="Returning to Home…" />
		)
	}

	return <PosFlowLoadingShell title={loadingCopy.title} subtitle={loadingCopy.subtitle} />
}
