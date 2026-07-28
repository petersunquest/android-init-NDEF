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
	fetchMyPosAddresses,
	fetchPosLedger,
	fetchWalletAssets,
	searchUsers,
	searchUsersByCardOwnerOrAdmin,
	setActivePosAddress,
	type PosCardBindingItem,
} from '@/api/beamioApi'
import {
	resolvePosBootPhase,
	runPosBootWalletCheck,
	type PosBootPhase,
} from '@/boot/posBootInit'
import { posNativeBridge } from '@/bridge/nativeBridge'
import { sendPosTerminalPermissionRequest } from '@/conet/posTerminalPermissionChat'
import type { MerchantActiveIssuedCoupon } from '@/utils/couponMetadata'
import type { TerminalProfile } from '@/types/pos'
import { posHomeTrustedCache, type PosOutboundJoinPending } from '@/utils/trustedCache'
import {
	resolveAdminProfileFromCardAdminInfo,
	resolveParentWorkspaceProfile,
} from '@/utils/posHomeAdminProfile'
import {
	parseMerchantInfraCardFromMyPos,
	resolvePosTerminalAccessAllowed,
} from '@/utils/posProgramCardAccess'
import { computeHomeStatsFromPosLedger } from '@/utils/posLedgerMetrics'
import { normalizeBeamioTagInput, pickExactBeamioTagProfile } from '@/utils/beamioTagRules'
import { getSessionPrivateKeyHex } from '@/wallet/posWalletSession'

function normEoa(raw: string | null | undefined): string {
	return (raw ?? '').trim().toLowerCase()
}

function resolveUpperFromAdminInfo(info: {
	upperAdmin?: string | null
	owner?: string | null
} | null | undefined): string | null {
	const upper = info?.upperAdmin?.trim()
	if (upper) return upper
	const owner = info?.owner?.trim()
	return owner || null
}

export type PosWorkspaceBindingRow = PosCardBindingItem & {
	upperEoa: string | null
	adminProfile: TerminalProfile | null
}

interface PosContextValue {
	walletAddress: string | null
	parentBeamioTag: string
	setParentBeamioTag: (tag: string) => void
	parentProfile: TerminalProfile | null
	setParentProfile: (p: TerminalProfile | null) => void
	terminalProfile: TerminalProfile | null
	adminProfile: TerminalProfile | null
	merchantInfraCard: string | null
	/** Active merchant upper admin / owner EOA — partition key for local cache. */
	activeUpperEoa: string | null
	workspaceBindings: PosWorkspaceBindingRow[]
	outboundJoinPending: PosOutboundJoinPending[]
	registeredBeamioTag: string | null
	currency: string
	chargeAmount: number | null
	topUpAmount: number | null
	tipsAmount: number | null
	bUnitBalance: number | null
	hasAAAccount: boolean | null
	homeStatsLoaded: boolean
	pointSystemEnabled: boolean
	/** `null` = never loaded / last fetch untrusted; `[]` = trusted empty. */
	activeCoupons: MerchantActiveIssuedCoupon[] | null
	activeCouponsLoaded: boolean
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
	/** Switch active merchant workspace (partition + DB active card). */
	switchWorkspace: (params: {
		upperEoa: string
		cardAddress: string
	}) => Promise<{ ok: true } | { ok: false; error: string }>
	/** Request to join another merchant parent via CoNET gossip. */
	requestJoinWorkspace: (params: {
		parentTag: string
		parentEoaHint?: string | null
	}) => Promise<{ ok: true } | { ok: false; error: string }>
	refreshWorkspaceBindings: () => Promise<void>
}

const PosContext = createContext<PosContextValue | null>(null)

function hydratePartitionIntoState(
	wallet: string,
	upper: string,
	setters: {
		setMerchantInfraCard: (v: string | null) => void
		setAdminProfile: (v: TerminalProfile | null) => void
		setParentProfile: (v: TerminalProfile | null) => void
		setParentBeamioTagState: (v: string) => void
		setChargeAmount: (v: number | null) => void
		setTopUpAmount: (v: number | null) => void
		setTipsAmount: (v: number | null) => void
		setPointSystemEnabled: (v: boolean) => void
		setActiveCoupons: (v: MerchantActiveIssuedCoupon[] | null) => void
		setShowPermissionGate: (v: boolean) => void
	},
): string | null {
	posHomeTrustedCache.ensureWorkspace(wallet, upper)
	const infra = posHomeTrustedCache.loadInfraCard(wallet, upper)
	if (infra) setters.setMerchantInfraCard(infra)
	const profiles = posHomeTrustedCache.loadProfiles(wallet, upper)
	if (profiles.admin) setters.setAdminProfile(profiles.admin)
	else setters.setAdminProfile(null)
	const parent = posHomeTrustedCache.loadParentProfile(wallet, upper)
	if (parent) setters.setParentProfile(parent)
	const parentTag = posHomeTrustedCache.loadParentTag(wallet, upper)
	if (parentTag) setters.setParentBeamioTagState(parentTag)
	if (infra) {
		const stats = posHomeTrustedCache.loadStats(wallet, upper, infra)
		if (stats.charge != null) setters.setChargeAmount(stats.charge)
		if (stats.topUp != null) setters.setTopUpAmount(stats.topUp)
		if (stats.tips != null) setters.setTipsAmount(stats.tips)
		const cachedPoint = posHomeTrustedCache.loadPointSystemEnabled(wallet, upper, infra)
		if (cachedPoint === true || cachedPoint === false) setters.setPointSystemEnabled(cachedPoint)
		const cachedCoupons = posHomeTrustedCache.loadActiveCoupons(wallet, upper, infra)
		if (cachedCoupons !== null) setters.setActiveCoupons(cachedCoupons)
	}
	const perm = posHomeTrustedCache.loadPermissionGranted(wallet, upper)
	if (perm === true) setters.setShowPermissionGate(false)
	else if (perm === false) setters.setShowPermissionGate(true)
	return infra
}

export function PosSessionProvider({ children }: { children: ReactNode }) {
	const [walletAddress, setWalletAddress] = useState<string | null>(null)
	const [parentBeamioTag, setParentBeamioTagState] = useState('')
	const [parentProfile, setParentProfile] = useState<TerminalProfile | null>(null)
	const [terminalProfile, setTerminalProfile] = useState<TerminalProfile | null>(null)
	const [adminProfile, setAdminProfile] = useState<TerminalProfile | null>(null)
	const [merchantInfraCard, setMerchantInfraCard] = useState<string | null>(null)
	const [activeUpperEoa, setActiveUpperEoa] = useState<string | null>(null)
	const [workspaceBindings, setWorkspaceBindings] = useState<PosWorkspaceBindingRow[]>([])
	const [outboundJoinPending, setOutboundJoinPending] = useState<PosOutboundJoinPending[]>([])
	const [registeredBeamioTag, setRegisteredBeamioTag] = useState<string | null>(null)
	const [currency, setCurrency] = useState('CAD')
	const [chargeAmount, setChargeAmount] = useState<number | null>(null)
	const [topUpAmount, setTopUpAmount] = useState<number | null>(null)
	const [tipsAmount, setTipsAmount] = useState<number | null>(null)
	const [bUnitBalance, setBUnitBalance] = useState<number | null>(null)
	const [hasAAAccount, setHasAAAccount] = useState<boolean | null>(null)
	const [homeStatsLoaded, setHomeStatsLoaded] = useState(false)
	const [pointSystemEnabled, setPointSystemEnabled] = useState(true)
	const [activeCoupons, setActiveCoupons] = useState<MerchantActiveIssuedCoupon[] | null>(null)
	const [showPermissionGate, setShowPermissionGate] = useState(false)
	const [isBootLoading, setIsBootLoading] = useState(true)
	const [bootPhase, setBootPhase] = useState<PosBootPhase | null>(null)
	const refreshGen = useRef(0)
	const refreshHomeRef = useRef<() => Promise<void>>(async () => {})
	const activeUpperRef = useRef<string | null>(null)
	activeUpperRef.current = activeUpperEoa

	const admitProgramCardAccess = useCallback(() => {
		setShowPermissionGate(false)
		setBootPhase('home')
		const w = walletAddress
		const u = activeUpperRef.current
		if (w && u) posHomeTrustedCache.savePermissionGranted(w, u, true)
	}, [walletAddress])

	const setParentBeamioTag = useCallback((tag: string) => {
		setParentBeamioTagState(tag)
	}, [])

	const refreshWorkspaceBindings = useCallback(async () => {
		const wallet = walletAddress ?? (await posNativeBridge.getWalletAddress())
		if (!wallet) return
		const items = await fetchMyPosAddresses(wallet)
		if (items === null) return
		const rows: PosWorkspaceBindingRow[] = []
		for (const item of items) {
			const info = await fetchCardAdminInfo(item.cardAddress, wallet)
			const upper = resolveUpperFromAdminInfo(info)
			let admin: TerminalProfile | null = null
			if (info?.ok) {
				const resolved = await resolveAdminProfileFromCardAdminInfo(info)
				if (resolved) admin = resolved
			}
			rows.push({
				...item,
				upperEoa: upper,
				adminProfile: admin,
			})
		}
		setWorkspaceBindings(rows)
		setOutboundJoinPending(posHomeTrustedCache.loadOutboundJoinPending(wallet))
	}, [walletAddress])

	const refreshHome = useCallback(async () => {
		const wallet = walletAddress ?? (await posNativeBridge.getWalletAddress())
		if (!wallet) return
		setWalletAddress(wallet)
		const gen = ++refreshGen.current

		let preferredUpper = activeUpperRef.current ?? posHomeTrustedCache.loadActiveUpper(wallet)
		let infra: string | null = preferredUpper
			? posHomeTrustedCache.loadInfraCard(wallet, preferredUpper)
			: null

		const posRes = await fetchMyPosAddress(wallet)
		if (gen !== refreshGen.current) return
		const apiInfra = parseMerchantInfraCardFromMyPos(posRes)

		if (preferredUpper && infra && apiInfra && normEoa(apiInfra) !== normEoa(infra)) {
			const align = await setActivePosAddress(wallet, infra)
			if (gen !== refreshGen.current) return
			if (!align.ok && apiInfra) {
				infra = apiInfra
			}
		} else if (apiInfra) {
			infra = apiInfra
		}

		if (posRes?.currency) setCurrency(posRes.currency)

		if (!infra) {
			setHomeStatsLoaded(true)
			return
		}

		const adminInfoEarly = await fetchCardAdminInfo(infra, wallet)
		if (gen !== refreshGen.current) return
		const cardUpper = resolveUpperFromAdminInfo(adminInfoEarly)

		if (preferredUpper && cardUpper && normEoa(preferredUpper) !== normEoa(cardUpper)) {
			const preferredInfra = posHomeTrustedCache.loadInfraCard(wallet, preferredUpper)
			if (preferredInfra) {
				const align = await setActivePosAddress(wallet, preferredInfra)
				if (gen !== refreshGen.current) return
				if (align.ok) {
					infra = preferredInfra
				} else {
					preferredUpper = cardUpper
					posHomeTrustedCache.saveActiveUpper(wallet, cardUpper)
					setActiveUpperEoa(cardUpper)
				}
			} else {
				preferredUpper = cardUpper
				posHomeTrustedCache.saveActiveUpper(wallet, cardUpper)
				setActiveUpperEoa(cardUpper)
			}
		} else if (cardUpper) {
			preferredUpper = cardUpper
			posHomeTrustedCache.saveActiveUpper(wallet, cardUpper)
			setActiveUpperEoa(cardUpper)
		}

		if (!preferredUpper) {
			setMerchantInfraCard(infra)
			setHomeStatsLoaded(true)
			return
		}

		const upper = preferredUpper
		posHomeTrustedCache.ensureWorkspace(wallet, upper)
		setMerchantInfraCard(infra)
		posHomeTrustedCache.saveInfraCard(wallet, upper, infra)

		const cachedStats = posHomeTrustedCache.loadStats(wallet, upper, infra)
		if (cachedStats.charge != null) setChargeAmount(cachedStats.charge)
		if (cachedStats.topUp != null) setTopUpAmount(cachedStats.topUp)
		if (cachedStats.tips != null) setTipsAmount(cachedStats.tips)
		const cachedPoint = posHomeTrustedCache.loadPointSystemEnabled(wallet, upper, infra)
		if (cachedPoint === true || cachedPoint === false) setPointSystemEnabled(cachedPoint)

		const cachedCoupons = posHomeTrustedCache.loadActiveCoupons(wallet, upper, infra)
		if (cachedCoupons !== null) setActiveCoupons(cachedCoupons)

		const [ledger, adminInfo, assets, coupons, pointEnabled] = await Promise.all([
			fetchPosLedger(wallet, infra),
			adminInfoEarly ?? fetchCardAdminInfo(infra, wallet),
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
			posHomeTrustedCache.savePosLedger(ledger, wallet, upper, infra)
			posHomeTrustedCache.mergeAndSaveStats(wallet, upper, infra, {
				charge: stats.charge,
				topUp: stats.topUp,
				tips: stats.tips,
				chargeUsdc: stats.chargeUsdc,
				tipsUsdc: stats.tipsUsdc,
			})
		}

		const access = await resolvePosTerminalAccessAllowed(infra, wallet, adminInfo)
		if (gen !== refreshGen.current) return
		if (access === true || access === false) {
			setShowPermissionGate(!access)
			posHomeTrustedCache.savePermissionGranted(wallet, upper, access)
			setBootPhase(access ? 'home' : 'permission')
		}
		if (adminInfo?.ok) {
			const resolvedAdmin = await resolveAdminProfileFromCardAdminInfo(adminInfo)
			if (gen !== refreshGen.current) return
			if (resolvedAdmin !== undefined) {
				if (resolvedAdmin) {
					setAdminProfile(resolvedAdmin)
					posHomeTrustedCache.saveAdmin(resolvedAdmin, wallet, upper)
				} else {
					setAdminProfile(null)
					posHomeTrustedCache.removeAdmin(wallet, upper)
				}
			}
		}

		const parentTag =
			parentBeamioTag.trim() || posHomeTrustedCache.loadParentTag(wallet, upper) || ''
		if (parentTag) {
			const parentResolved = await resolveParentWorkspaceProfile(parentTag)
			if (gen !== refreshGen.current) return
			if (parentResolved !== undefined && parentResolved) {
				setParentProfile(parentResolved)
				posHomeTrustedCache.saveParentProfile(parentResolved, wallet, upper)
				posHomeTrustedCache.saveParentTag(wallet, parentTag, upper)
			}
		}

		if (assets && typeof assets.hasAAAccount === 'boolean') {
			setHasAAAccount(assets.hasAAAccount)
		}

		if (coupons !== null) {
			setActiveCoupons(coupons)
			posHomeTrustedCache.saveActiveCoupons(wallet, upper, infra, coupons)
		}
		if (pointEnabled === true || pointEnabled === false) {
			setPointSystemEnabled(pointEnabled)
			posHomeTrustedCache.savePointSystemEnabled(wallet, upper, infra, pointEnabled)
		}

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
		void refreshWorkspaceBindings()
	}, [walletAddress, registeredBeamioTag, parentBeamioTag, refreshWorkspaceBindings])

	refreshHomeRef.current = refreshHome

	const switchWorkspace = useCallback(
		async (params: { upperEoa: string; cardAddress: string }) => {
			const wallet = walletAddress ?? (await posNativeBridge.getWalletAddress())
			if (!wallet) return { ok: false as const, error: 'No terminal wallet.' }
			const upper = params.upperEoa.trim()
			const card = params.cardAddress.trim()
			if (!upper || !card) return { ok: false as const, error: 'Missing merchant workspace.' }

			const setRes = await setActivePosAddress(wallet, card)
			if (!setRes.ok) return { ok: false as const, error: setRes.error }

			posHomeTrustedCache.saveActiveUpper(wallet, upper)
			posHomeTrustedCache.saveInfraCard(wallet, upper, setRes.cardAddress)
			setActiveUpperEoa(upper)
			hydratePartitionIntoState(wallet, upper, {
				setMerchantInfraCard,
				setAdminProfile,
				setParentProfile,
				setParentBeamioTagState,
				setChargeAmount,
				setTopUpAmount,
				setTipsAmount,
				setPointSystemEnabled,
				setActiveCoupons,
				setShowPermissionGate,
			})
			setMerchantInfraCard(setRes.cardAddress)
			await refreshHomeRef.current()
			return { ok: true as const }
		},
		[walletAddress],
	)

	const requestJoinWorkspace = useCallback(
		async (params: { parentTag: string; parentEoaHint?: string | null }) => {
			const wallet = walletAddress
			if (!wallet) return { ok: false as const, error: 'No terminal wallet.' }
			const childTag = registeredBeamioTag?.trim()
			if (!childTag) return { ok: false as const, error: 'Terminal @BeamioTag is missing.' }
			const pk = getSessionPrivateKeyHex()
			if (!pk) {
				return {
					ok: false as const,
					error: 'Signing key is not available. Restore the terminal wallet and try again.',
				}
			}

			const parentTag = normalizeBeamioTagInput(params.parentTag)
			let parentEoaHint = params.parentEoaHint?.trim() ?? ''
			if (!parentEoaHint) {
				const rows =
					(await searchUsersByCardOwnerOrAdmin(parentTag)) ?? (await searchUsers(parentTag))
				const exact = pickExactBeamioTagProfile(rows, parentTag)
				parentEoaHint = exact?.address?.trim() ?? ''
				if (!parentEoaHint) {
					return {
						ok: false as const,
						error: 'Could not uniquely resolve that @BeamioTag. Check the handle and try again.',
					}
				}
			}

			const sent = await sendPosTerminalPermissionRequest({
				walletPrivateKeyHex: pk,
				childEoa: wallet,
				childBeamioTag: childTag,
				parentBeamioTag: parentTag,
				parentEoaHint,
			})
			if (!sent.ok) return { ok: false as const, error: sent.error }

			posHomeTrustedCache.appendOutboundJoinPending(wallet, {
				parentTag,
				parentEoa: sent.recipientEoa,
				requestedAt: Date.now(),
			})
			setOutboundJoinPending(posHomeTrustedCache.loadOutboundJoinPending(wallet))
			return { ok: true as const }
		},
		[walletAddress, registeredBeamioTag],
	)

	/** App.tsx `init()` — checkStorage, hydrate session, one admin probe before routing. */
	useEffect(() => {
		let cancelled = false
		void (async () => {
			setIsBootLoading(true)
			try {
				const boot = await runPosBootWalletCheck()
				if (cancelled) return

				if (boot.needsWalletRecover && boot.recoverHint) {
					const hint = boot.recoverHint
					setWalletAddress(hint.walletAddress)
					setRegisteredBeamioTag(hint.registeredTag)
					if (hint.parentTag) setParentBeamioTagState(hint.parentTag)
					setBootPhase('wallet_recover')
					setIsBootLoading(false)
					return
				}

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

				const activeUpper = posHomeTrustedCache.loadActiveUpper(addr)
				if (activeUpper) {
					setActiveUpperEoa(activeUpper)
					hydratePartitionIntoState(addr, activeUpper, {
						setMerchantInfraCard,
						setAdminProfile,
						setParentProfile,
						setParentBeamioTagState,
						setChargeAmount,
						setTopUpAmount,
						setTipsAmount,
						setPointSystemEnabled,
						setActiveCoupons,
						setShowPermissionGate,
					})
				} else {
					const parent =
						record?.parentBeamioTag?.trim() || posHomeTrustedCache.loadParentTag(addr)
					if (parent) setParentBeamioTagState(parent)
					const cached = posHomeTrustedCache.loadProfiles(addr, null)
					if (cached.terminal) setTerminalProfile(cached.terminal)
					const cachedParent = posHomeTrustedCache.loadParentProfile(addr, null)
					if (cachedParent) setParentProfile(cachedParent)
					const infra = posHomeTrustedCache.loadInfraCard(addr, null)
					if (infra) setMerchantInfraCard(infra)
				}

				const termCached = posHomeTrustedCache.loadProfiles(addr, activeUpper).terminal
				if (termCached) setTerminalProfile(termCached)

				setOutboundJoinPending(posHomeTrustedCache.loadOutboundJoinPending(addr))

				await refreshHomeRef.current()
				if (cancelled) return

				const upperAfter = activeUpperRef.current ?? posHomeTrustedCache.loadActiveUpper(addr)
				const permAfter = posHomeTrustedCache.loadPermissionGranted(addr, upperAfter)
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
			void (async () => {
				const parentResolved = await resolveParentWorkspaceProfile(params.parentTag)
				if (parentResolved) {
					setParentProfile(parentResolved)
					posHomeTrustedCache.saveParentProfile(parentResolved, params.wallet)
				}
			})()
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
			activeUpperEoa,
			workspaceBindings,
			outboundJoinPending,
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
			activeCouponsLoaded: activeCoupons !== null,
			showPermissionGate,
			isBootLoading,
			bootPhase,
			refreshHome,
			admitProgramCardAccess,
			markOnboardingComplete,
			clearSessionForNewWorkspace,
			switchWorkspace,
			requestJoinWorkspace,
			refreshWorkspaceBindings,
		}),
		[
			walletAddress,
			parentBeamioTag,
			parentProfile,
			terminalProfile,
			adminProfile,
			merchantInfraCard,
			activeUpperEoa,
			workspaceBindings,
			outboundJoinPending,
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
			switchWorkspace,
			requestJoinWorkspace,
			refreshWorkspaceBindings,
		],
	)

	return <PosContext.Provider value={value}>{children}</PosContext.Provider>
}

export function usePosSession(): PosContextValue {
	const ctx = useContext(PosContext)
	if (!ctx) throw new Error('usePosSession must be used within PosSessionProvider')
	return ctx
}
