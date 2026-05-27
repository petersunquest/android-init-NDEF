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
import {
	fetchActiveCoupons,
	fetchBUnitBalance,
	fetchCardAdminInfo,
	fetchCardMetadataPointSystem,
	fetchMyPosAddress,
	fetchPosLedger,
	fetchWalletAssets,
	searchUsers,
} from '@/api/beamioApi'
import {
	resolvePosBootPhase,
	runPosBootWalletCheck,
	type PosBootPhase,
} from '@/boot/posBootInit'
import { posNativeBridge } from '@/bridge/nativeBridge'
import type { MerchantActiveIssuedCoupon } from '@/utils/couponMetadata'
import type { TerminalProfile } from '@/types/pos'
import { posHomeTrustedCache } from '@/utils/trustedCache'
import {
	parseMerchantInfraCardFromMyPos,
	resolvePosTerminalAccessAllowed,
} from '@/utils/posProgramCardAccess'
import { computeHomeStatsFromPosLedger } from '@/utils/posLedgerMetrics'

interface PosContextValue {
	walletAddress: string | null
	parentBeamioTag: string
	setParentBeamioTag: (tag: string) => void
	parentProfile: TerminalProfile | null
	setParentProfile: (p: TerminalProfile | null) => void
	terminalProfile: TerminalProfile | null
	adminProfile: TerminalProfile | null
	merchantInfraCard: string | null
	registeredBeamioTag: string | null
	currency: string
	chargeAmount: number | null
	topUpAmount: number | null
	tipsAmount: number | null
	bUnitBalance: number | null
	hasAAAccount: boolean | null
	homeStatsLoaded: boolean
	pointSystemEnabled: boolean
	activeCoupons: MerchantActiveIssuedCoupon[] | null
	showPermissionGate: boolean
	/** SilentPassUI `isInitialLoading` — true until first `checkStorage` boot finishes. */
	isBootLoading: boolean
	bootPhase: PosBootPhase | null
	refreshHome: () => Promise<void>
	admitProgramCardAccess: () => void
	markOnboardingComplete: (params: {
		wallet: string
		accountName: string
		parentTag: string
	}) => void
	clearSessionForNewWorkspace: () => void
}

const PosContext = createContext<PosContextValue | null>(null)

export function PosSessionProvider({ children }: { children: ReactNode }) {
	const [walletAddress, setWalletAddress] = useState<string | null>(null)
	const [parentBeamioTag, setParentBeamioTagState] = useState('')
	const [parentProfile, setParentProfile] = useState<TerminalProfile | null>(null)
	const [terminalProfile, setTerminalProfile] = useState<TerminalProfile | null>(null)
	const [adminProfile, setAdminProfile] = useState<TerminalProfile | null>(null)
	const [merchantInfraCard, setMerchantInfraCard] = useState<string | null>(null)
	const [registeredBeamioTag, setRegisteredBeamioTag] = useState<string | null>(null)
	const [currency, setCurrency] = useState('CAD')
	const [chargeAmount, setChargeAmount] = useState<number | null>(null)
	const [topUpAmount, setTopUpAmount] = useState<number | null>(null)
	const [tipsAmount, setTipsAmount] = useState<number | null>(null)
	const [bUnitBalance, setBUnitBalance] = useState<number | null>(null)
	const [hasAAAccount, setHasAAAccount] = useState<boolean | null>(null)
	const [homeStatsLoaded, setHomeStatsLoaded] = useState(false)
	const [pointSystemEnabled, setPointSystemEnabled] = useState(false)
	const [activeCoupons, setActiveCoupons] = useState<MerchantActiveIssuedCoupon[] | null>(null)
	const [showPermissionGate, setShowPermissionGate] = useState(false)
	const [isBootLoading, setIsBootLoading] = useState(true)
	const [bootPhase, setBootPhase] = useState<PosBootPhase | null>(null)
	const refreshGen = useRef(0)
	const refreshHomeRef = useRef<() => Promise<void>>(async () => {})

	const admitProgramCardAccess = useCallback(() => {
		setShowPermissionGate(false)
		setBootPhase('home')
		const w = walletAddress
		if (w) posHomeTrustedCache.savePermissionGranted(w, true)
	}, [walletAddress])

	const setParentBeamioTag = useCallback((tag: string) => {
		setParentBeamioTagState(tag)
	}, [])

	const refreshHome = useCallback(async () => {
		const wallet = walletAddress ?? (await posNativeBridge.getWalletAddress())
		if (!wallet) return
		setWalletAddress(wallet)
		const gen = ++refreshGen.current

		const posRes = await fetchMyPosAddress(wallet)
		if (gen !== refreshGen.current) return
		let infra = merchantInfraCard
		const parsedInfra = parseMerchantInfraCardFromMyPos(posRes)
		if (parsedInfra) {
			infra = parsedInfra
			setMerchantInfraCard(infra)
			posHomeTrustedCache.saveInfraCard(wallet, infra)
		}
		if (posRes?.currency) setCurrency(posRes.currency)

		if (!infra) {
			setHomeStatsLoaded(true)
			return
		}

		const cachedStats = posHomeTrustedCache.loadStats(wallet, infra)
		if (cachedStats.charge != null) setChargeAmount(cachedStats.charge)
		if (cachedStats.topUp != null) setTopUpAmount(cachedStats.topUp)
		if (cachedStats.tips != null) setTipsAmount(cachedStats.tips)

		const [ledger, adminInfo, assets, coupons, pointEnabled] = await Promise.all([
			fetchPosLedger(wallet, infra),
			fetchCardAdminInfo(infra, wallet),
			fetchWalletAssets(wallet, infra),
			fetchActiveCoupons(infra),
			fetchCardMetadataPointSystem(infra),
		])
		if (gen !== refreshGen.current) return

		if (ledger) {
			const stats = computeHomeStatsFromPosLedger(ledger)
			setChargeAmount(stats.charge)
			setTopUpAmount(stats.topUp)
			setTipsAmount(stats.tips)
			posHomeTrustedCache.savePosLedger(ledger, wallet, infra)
			posHomeTrustedCache.mergeAndSaveStats(wallet, infra, {
				charge: stats.charge,
				topUp: stats.topUp,
				tips: stats.tips,
				chargeUsdc: stats.chargeUsdc,
				tipsUsdc: stats.tipsUsdc,
			})
		}

		if (infra) {
			const access = await resolvePosTerminalAccessAllowed(infra, wallet, adminInfo)
			if (gen !== refreshGen.current) return
			if (access === true || access === false) {
				setShowPermissionGate(!access)
				posHomeTrustedCache.savePermissionGranted(wallet, access)
				setBootPhase(access ? 'home' : 'permission')
			}
			if (adminInfo?.upperAdmin) {
				const upper = await searchUsers(adminInfo.upperAdmin)
				if (gen !== refreshGen.current) return
				if (upper?.[0]) {
					setAdminProfile(upper[0])
					posHomeTrustedCache.saveAdmin(upper[0], wallet)
				}
			} else if (adminInfo?.ok) {
				setAdminProfile(null)
				posHomeTrustedCache.removeAdmin(wallet)
			}
		}

		if (assets && typeof assets.hasAAAccount === 'boolean') {
			setHasAAAccount(assets.hasAAAccount)
		}

		if (coupons) setActiveCoupons(coupons)
		if (pointEnabled === true || pointEnabled === false) setPointSystemEnabled(pointEnabled)

		const bUnitTarget = adminInfo?.upperAdmin ?? adminInfo?.owner
		if (bUnitTarget) {
			const bal = await fetchBUnitBalance(bUnitTarget)
			if (gen !== refreshGen.current) return
			if (bal != null) setBUnitBalance(bal)
		}

		const termTag = registeredBeamioTag ?? posHomeTrustedCache.loadRegisteredTag(wallet)
		if (termTag) {
			const termSearch = await searchUsers(termTag)
			if (gen !== refreshGen.current) return
			if (termSearch?.[0]) {
				setTerminalProfile(termSearch[0])
				posHomeTrustedCache.saveTerminal(termSearch[0], wallet)
			}
		}

		setHomeStatsLoaded(true)
	}, [walletAddress, merchantInfraCard, registeredBeamioTag])

	refreshHomeRef.current = refreshHome

	/** App.tsx `init()` — checkStorage, hydrate session, one admin probe before routing. */
	useEffect(() => {
		let cancelled = false
		void (async () => {
			setIsBootLoading(true)
			try {
				const boot = await runPosBootWalletCheck()
				if (cancelled) return

				if (!boot.hasStoredWallet || !boot.walletAddress) {
					setBootPhase('no_wallet')
					setIsBootLoading(false)
					return
				}

				const addr = boot.walletAddress
				setWalletAddress(addr)

				const record = boot.walletRecord
				const regTag =
					record?.profiles[0]?.accountName?.trim() ||
					posHomeTrustedCache.loadRegisteredTag(addr)
				if (regTag) setRegisteredBeamioTag(regTag)
				const parent =
					record?.parentBeamioTag?.trim() || posHomeTrustedCache.loadParentTag(addr)
				if (parent) setParentBeamioTagState(parent)

				const cached = posHomeTrustedCache.loadProfiles(addr)
				if (cached.terminal) setTerminalProfile(cached.terminal)
				if (cached.admin) setAdminProfile(cached.admin)
				const infra = posHomeTrustedCache.loadInfraCard(addr)
				if (infra) setMerchantInfraCard(infra)
				if (infra) {
					const stats = posHomeTrustedCache.loadStats(addr, infra)
					if (stats.charge != null) setChargeAmount(stats.charge)
					if (stats.topUp != null) setTopUpAmount(stats.topUp)
					if (stats.tips != null) setTipsAmount(stats.tips)
				}

				const permCached = posHomeTrustedCache.loadPermissionGranted(addr)
				if (permCached === true) {
					setShowPermissionGate(false)
				} else if (permCached === false) {
					setShowPermissionGate(true)
				}

				await refreshHomeRef.current()
				if (cancelled) return

				const permAfter = posHomeTrustedCache.loadPermissionGranted(addr)
				const phase = resolvePosBootPhase({
					hasStoredWallet: true,
					accessGranted:
						permAfter === true ? true : permAfter === false ? false : null,
					permCached: permAfter,
				})
				setBootPhase(phase)
				if (phase === 'home') setShowPermissionGate(false)
				if (phase === 'permission') setShowPermissionGate(true)
			} finally {
				if (!cancelled) setIsBootLoading(false)
			}
		})()
		return () => {
			cancelled = true
		}
	}, [])

	const markOnboardingComplete = useCallback(
		(params: { wallet: string; accountName: string; parentTag: string }) => {
			setWalletAddress(params.wallet)
			setRegisteredBeamioTag(params.accountName)
			setParentBeamioTagState(params.parentTag)
			posHomeTrustedCache.saveRegisteredTag(params.wallet, params.accountName)
			posHomeTrustedCache.saveParentTag(params.wallet, params.parentTag)
			setShowPermissionGate(true)
			setBootPhase('permission')
			posHomeTrustedCache.savePermissionGranted(params.wallet, false)
		},
		[],
	)

	const clearSessionForNewWorkspace = useCallback(() => {
		setParentProfile(null)
		setParentBeamioTagState('')
	}, [])

	const value = useMemo<PosContextValue>(
		() => ({
			walletAddress,
			parentBeamioTag,
			setParentBeamioTag,
			parentProfile,
			setParentProfile,
			terminalProfile,
			adminProfile,
			merchantInfraCard,
			registeredBeamioTag,
			currency,
			chargeAmount,
			topUpAmount,
			tipsAmount,
			bUnitBalance,
			hasAAAccount,
			homeStatsLoaded,
			pointSystemEnabled,
			activeCoupons,
			showPermissionGate,
			isBootLoading,
			bootPhase,
			refreshHome,
			admitProgramCardAccess,
			markOnboardingComplete,
			clearSessionForNewWorkspace,
		}),
		[
			walletAddress,
			parentBeamioTag,
			parentProfile,
			terminalProfile,
			adminProfile,
			merchantInfraCard,
			registeredBeamioTag,
			currency,
			chargeAmount,
			topUpAmount,
			tipsAmount,
			bUnitBalance,
			hasAAAccount,
			homeStatsLoaded,
			pointSystemEnabled,
			activeCoupons,
			showPermissionGate,
			isBootLoading,
			bootPhase,
			refreshHome,
			admitProgramCardAccess,
			markOnboardingComplete,
			clearSessionForNewWorkspace,
		],
	)

	return <PosContext.Provider value={value}>{children}</PosContext.Provider>
}

export function usePosSession(): PosContextValue {
	const ctx = useContext(PosContext)
	if (!ctx) throw new Error('usePosSession must be used within PosSessionProvider')
	return ctx
}
