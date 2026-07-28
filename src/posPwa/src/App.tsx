import { lazy, Suspense, useEffect } from 'react'
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

/** True when current URL is allowed for the resolved boot phase (no stale /recover paint). */
function pathAllowedForBootPhase(phase: PosBootPhase, path: string): boolean {
	switch (phase) {
		case 'no_wallet':
			return SETUP_PATHS.has(path)
		case 'wallet_recover':
			return path === '/recover'
		case 'permission':
			return path === '/permission'
		case 'home':
			return isPosHomePhasePath(path)
		default:
			return false
	}
}

function BootRouter() {
	const navigate = useNavigate()
	const location = useLocation()
	const { isBootLoading, bootPhase, showPermissionGate, walletAddress } = usePosSession()

	useEffect(() => {
		if (isBootLoading || bootPhase == null) return

		const target = bootPathForPhase(bootPhase)
		const path = location.pathname

		if (path === target) return

		if (bootPhase === 'no_wallet') {
			if (!SETUP_PATHS.has(path)) navigate('/', { replace: true })
			return
		}

		if (bootPhase === 'wallet_recover') {
			if (path !== '/recover') navigate('/recover', { replace: true })
			return
		}

		if (bootPhase === 'permission') {
			if (path !== '/permission') navigate('/permission', { replace: true })
			return
		}

		if (bootPhase === 'home') {
			if (!isPosHomePhasePath(path)) navigate('/home', { replace: true })
		}
	}, [isBootLoading, bootPhase, location.pathname, navigate])

	/** Daemon may flip gate while user stays on permission — promote to home. */
	useEffect(() => {
		if (isBootLoading || !walletAddress) return
		if (!showPermissionGate && location.pathname === '/permission') {
			navigate('/home', { replace: true })
		}
	}, [isBootLoading, walletAddress, showPermissionGate, location.pathname, navigate])

	/*
	 * Keep splash until URL matches boot phase. Otherwise a restored WebView URL
	 * (/recover, /onboarding) paints Access password for a frame before redirect to /home.
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
