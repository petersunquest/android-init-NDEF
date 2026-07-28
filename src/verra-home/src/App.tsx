import { lazy, Suspense } from 'react'
import { BrowserRouter, Route, Routes } from 'react-router-dom'

/** All routes lazy: keeps the entry chunk small (viem/x402 only load with the page that needs them). */
const Home = lazy(() => import('./pages/Home').then((m) => ({ default: m.Home })))
const TheLocal = lazy(() => import('./pages/TheLocal').then((m) => ({ default: m.TheLocal })))
const ForBusiness = lazy(() => import('./pages/ForBusiness').then((m) => ({ default: m.ForBusiness })))
const Impact = lazy(() => import('./pages/Impact').then((m) => ({ default: m.Impact })))
const TermsOfService = lazy(() => import('./pages/TermsOfService').then((m) => ({ default: m.TermsOfService })))
const PrivacyPolicy = lazy(() => import('./pages/PrivacyPolicy').then((m) => ({ default: m.PrivacyPolicy })))
const Contact = lazy(() => import('./pages/Contact').then((m) => ({ default: m.Contact })))
const UsdcCharge = lazy(() => import('./pages/UsdcCharge').then((m) => ({ default: m.UsdcCharge })))
const UsdcTopup = lazy(() => import('./pages/UsdcTopup').then((m) => ({ default: m.UsdcTopup })))
const Vouchers = lazy(() => import('./pages/Vouchers').then((m) => ({ default: m.Vouchers })))

function RouteFallback() {
	return (
		<div
			className="flex min-h-dvh items-center justify-center px-6 text-center antialiased"
			style={{ background: '#f9f9fe', color: '#1a1c1f' }}
		>
			<p className="text-sm font-medium">Loading…</p>
		</div>
	)
}

function App() {
	return (
		<BrowserRouter>
			<Suspense fallback={<RouteFallback />}>
				<Routes>
					<Route path="/" element={<Home />} />
					<Route path="/local" element={<TheLocal />} />
					<Route path="/business" element={<ForBusiness />} />
					<Route path="/impact" element={<Impact />} />
					<Route path="/terms" element={<TermsOfService />} />
					<Route path="/privacy" element={<PrivacyPolicy />} />
					<Route path="/contact" element={<Contact />} />
					<Route path="/usdc-topup" element={<UsdcTopup />} />
					<Route path="/usdc-charge" element={<UsdcCharge />} />
					<Route path="/Vouchers" element={<Vouchers />} />
					<Route path="/vouchers" element={<Vouchers />} />
				</Routes>
			</Suspense>
		</BrowserRouter>
	)
}

export default App
