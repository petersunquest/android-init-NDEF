import { lazy, Suspense, useEffect, useRef } from 'react'
import { BrowserRouter, Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { bootPathForPhase, type PosBootPhase } from '@/boot/posBootInit'
import { PosAppBootSplash } from '@/components/PosAppBootSplash'
import { PosDataDaemonProvider } from '@/providers/PosDataDaemonProvider'
import { IpfsImageLibraryProvider } from '@/providers/IpfsImageLibraryProvider'
import { PosSessionProvider, usePosSession } from '@/providers/PosSessionProvider'
import { isPosHomePhasePath } from '@/utils/posHomeActionRoutes'

const WelcomePage = lazy(() =>
	import('@/pages/WelcomePage').then((m) => ({ default: m.WelcomePage })),
)
const OnboardingPage = lazy(() =>
	import('@/pages/OnboardingPage').then((m) => ({ default: m.OnboardingPage })),
)
const PosWalletRecoverPage = lazy(() =>
	import('@/pages/PosWalletRecoverPage').then((m) => ({ default: m.PosWalletRecoverPage })),
)
const ParentPermissionGatePage = lazy(() =>
	import('@/pages/ParentPermissionGatePage').then((m) => ({
		default: m.ParentPermissionGatePage,
	})),
)
const HomePage = lazy(() => import('@/pages/HomePage').then((m) => ({ default: m.HomePage })))
const CheckBalancePage = lazy(() =>
	import('@/pages/CheckBalancePage').then((m) => ({ default: m.CheckBalancePage })),
)
const TopUpPage = lazy(() => import('@/pages/TopUpPage').then((m) => ({ default: m.TopUpPage })))
const ChargePage = lazy(() => import('@/pages/ChargePage').then((m) => ({ default: m.ChargePage })))
const DeductPointsPage = lazy(() =>
	import('@/pages/DeductPointsPage').then((m) => ({ default: m.DeductPointsPage })),
)
const TransactionsPage = lazy(() =>
	import('@/pages/TransactionsPage').then((m) => ({ default: m.TransactionsPage })),
)
const ActiveCouponsPage = lazy(() =>
	import('@/pages/ActiveCouponsPage').then((m) => ({ default: m.ActiveCouponsPage })),
)
const WorkspaceMerchantsPage = lazy(() =>
	import('@/pages/WorkspaceMerchantsPage').then((m) => ({ default: m.WorkspaceMerchantsPage })),
)
const NativeActionPage = lazy(() =>
	import('@/pages/NativeActionPage').then((m) => ({ default: m.NativeActionPage })),
)

const SETUP_PATHS = new Set(['/', '/onboarding'])

function RouteFallback() {
	return <PosAppBootSplash />
}

/** True when current URL is allowed for the resolved boot phase (no stale setup paint). */
function pathAllowedForBootPhase(phase: PosBootPhase, path: string): boolean {
	switch (phase) {
		case 'no_wallet':
			return SETUP_PATHS.has(path) || path === '/recover'
		case 'permission':
			return path === '/permission'
		case 'workspace':
			return path === '/workspace' || path === '/recover'
		case 'home':
			return isPosHomePhasePath(path)
		default:
			return false
	}
}

function BootRouter() {
	const navigate = useNavigate()
	const location = useLocation()
	const { isBootLoading, bootPhase } = usePosSession()

	useEffect(() => {
		if (isBootLoading || bootPhase == null) return

		const target = bootPathForPhase(bootPhase)
		const path = location.pathname

		if (path === target) return

		if (bootPhase === 'no_wallet') {
			if (path === '/recover') {
				navigate('/', { replace: true })
				return
			}
			if (!SETUP_PATHS.has(path)) navigate('/', { replace: true })
			return
		}

		if (bootPhase === 'permission') {
			if (path !== '/permission') navigate('/permission', { replace: true })
			return
		}

		if (bootPhase === 'workspace') {
			if (path !== '/workspace' && path !== '/recover') {
				navigate('/workspace', { replace: true })
			}
			return
		}

		if (bootPhase === 'home') {
			if (!isPosHomePhasePath(path)) navigate('/home', { replace: true })
		}
	}, [isBootLoading, bootPhase, location.pathname, navigate])

	/**
	 * Leave forced wait screens only when boot phase *transitions* into home
	 * (admin just granted). Do not bounce voluntary /workspace visits from Home
	 * (upper-admin capsule) — that caused a one-frame flicker then snap back.
	 */
	const prevBootPhaseRef = useRef<PosBootPhase | null>(null)
	useEffect(() => {
		const prev = prevBootPhaseRef.current
		prevBootPhaseRef.current = bootPhase
		if (isBootLoading || bootPhase == null) return
		if (bootPhase !== 'home') return
		if (prev !== 'permission' && prev !== 'workspace') return
		if (location.pathname === '/permission' || location.pathname === '/workspace') {
			navigate('/home', { replace: true })
		}
	}, [isBootLoading, bootPhase, location.pathname, navigate])

	/*
	 * Keep splash until URL matches boot phase. Otherwise a restored WebView URL
	 * (/recover, /onboarding) can paint setup UI for a frame before redirect to /home.
	 */
	if (isBootLoading || bootPhase == null) {
		return <RouteFallback />
	}

	if (!pathAllowedForBootPhase(bootPhase, location.pathname)) {
		return <RouteFallback />
	}

	return (
		<Suspense fallback={<RouteFallback />}>
			<Routes>
				<Route path="/" element={<WelcomePage />} />
				<Route path="/onboarding" element={<OnboardingPage />} />
				<Route path="/recover" element={<PosWalletRecoverPage />} />
				<Route path="/permission" element={<ParentPermissionGatePage />} />
				<Route path="/home" element={<HomePage />} />
				<Route path="/check-balance" element={<CheckBalancePage />} />
				<Route path="/topup" element={<TopUpPage />} />
				<Route path="/charge" element={<ChargePage />} />
				<Route path="/deduct-points" element={<DeductPointsPage />} />
				<Route path="/transactions" element={<TransactionsPage />} />
				<Route path="/active-coupons" element={<ActiveCouponsPage />} />
				<Route path="/workspace" element={<WorkspaceMerchantsPage />} />
				<Route path="/native/:action" element={<NativeActionPage />} />
				<Route path="*" element={<Navigate to="/" replace />} />
			</Routes>
		</Suspense>
	)
}

const routerBasename = import.meta.env.BASE_URL.replace(/\/$/, '')

export default function App() {
	return (
		<BrowserRouter basename={routerBasename || undefined}>
			<PosSessionProvider>
				<IpfsImageLibraryProvider>
					<PosDataDaemonProvider>
						<BootRouter />
					</PosDataDaemonProvider>
				</IpfsImageLibraryProvider>
			</PosSessionProvider>
		</BrowserRouter>
	)
}
