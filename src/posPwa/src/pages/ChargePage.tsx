import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { fetchWalletAssets } from '@/api/beamioApi'
import { ChargeAmountPadPage } from '@/components/ChargeAmountPadPage'
import { ChargeSelectProgramCardPage } from '@/components/ChargeSelectProgramCardPage'
import {
	ChargeInsufficientFundsView,
	ChargeSuccessView,
} from '@/components/ChargeSuccessView'
import { ChargeTipPage } from '@/components/ChargeTipPage'
import { PosFlowLoadingShell } from '@/components/PosFlowLoadingShell'
import { PosPaymentRoutingMonitorCard } from '@/components/PosPaymentRoutingMonitorCard'
import { PosScanExecutingShell } from '@/components/PosScanExecutingShell'
import { TopupUsdcQrPanel } from '@/components/TopupUsdcQrPanel'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { ChargePaymentMethodRaw } from '@/utils/chargePaymentMethod'
import { POS_TERMINAL_CHARGE_POLICY_ALL } from '@/utils/chargePaymentMethod'
import {
	executeNfcCharge,
	executeQrCharge,
	type ChargeExecuteSuccess,
} from '@/utils/chargeExecute'
import {
	pollUsdcChargeSession,
	prepareUsdcChargeQr,
	usdcChargeCustomerHint,
} from '@/utils/chargeUsdcSession'
import { chargeTipFromRequestAndBps } from '@/utils/beamioPaymentRouting'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import type { PosHomeLocationState } from '@/utils/posHomeLocationState'
import { cancelPosCustomerScan, runPosChargeScanFlow } from '@/utils/posScanFlow'
import {
	makeInitialPaymentRoutingSteps,
	patchPaymentRoutingStep,
	type PaymentRoutingStep,
} from '@/utils/paymentRoutingSteps'
import { isExternalWalletStablecoinMethod } from '@/utils/topupPaymentMethod'
import {
	fetchChargeAdminCardBalances,
	pickDefaultChargeAdminCard,
	resolvePosAdminMerchantCards,
	type ChargeAdminCardBalanceRow,
	type ChargePendingCustomer,
} from '@/utils/chargeAdminCardBalances'

type ChargePhase =
	| 'amount'
	| 'tip'
	| 'scan-customer'
	| 'select-card'
	| 'executing'
	| 'usdc-qr'
	| 'success'
	| 'insufficient'

interface ChargeDraft {
	subtotal: string
	methodRaw: ChargePaymentMethodRaw
	tipBps: number
}

/**
 * iOS-aligned Charge: amount pad → tip → NFC/QR (program card) or USDC QR → success.
 */
export function ChargePage() {
	const navigate = useNavigate()
	const {
		merchantInfraCard,
		walletAddress,
		refreshHome,
		pointSystemEnabled,
		currency,
		workspaceBindings,
	} = usePosSession()

	const [phase, setPhase] = useState<ChargePhase>('amount')
	const [draft, setDraft] = useState<ChargeDraft | null>(null)
	const [success, setSuccess] = useState<ChargeExecuteSuccess | null>(null)
	const [insufficient, setInsufficient] = useState<{
		message: string
		requiredLabel?: string
		availableLabel?: string
	} | null>(null)
	const [programCardName, setProgramCardName] = useState('')
	const [usdcDeepLink, setUsdcDeepLink] = useState('')
	const [usdcHint, setUsdcHint] = useState('')
	const [usdcProgress, setUsdcProgress] = useState('')
	const [usdcSid, setUsdcSid] = useState('')
	const [usdcPrepared, setUsdcPrepared] = useState<{
		total: number
		currency: string
		taxBps: number
	} | null>(null)
	const pollAbortRef = useRef<AbortController | null>(null)
	const scanStartedRef = useRef(false)
	const [pendingCustomer, setPendingCustomer] = useState<ChargePendingCustomer | null>(null)
	const [adminCardAddresses, setAdminCardAddresses] = useState<string[]>([])
	const [adminCardRows, setAdminCardRows] = useState<ChargeAdminCardBalanceRow[]>([])
	const [adminCardsLoading, setAdminCardsLoading] = useState(false)
	const [selectedChargeCard, setSelectedChargeCard] = useState('')
	const [selectConfirming, setSelectConfirming] = useState(false)
	const adminBalanceReqRef = useRef(0)
	const [routingSteps, setRoutingSteps] = useState<PaymentRoutingStep[]>(() =>
		makeInitialPaymentRoutingSteps(),
	)

	const patchRoutingStep = useCallback(
		(id: string, status: PaymentRoutingStep['status'], detail?: string) => {
			setRoutingSteps((prev) => patchPaymentRoutingStep(prev, id, status, detail))
		},
		[],
	)

	useEffect(() => {
		const infra = merchantInfraCard?.trim()
		const wallet = walletAddress?.trim()
		if (!infra || !wallet) return
		let cancelled = false
		void fetchWalletAssets(wallet, infra).then((res) => {
			if (cancelled) return
			const name = res?.cardName?.trim()
			if (name) setProgramCardName(name)
		})
		return () => {
			cancelled = true
		}
	}, [merchantInfraCard, walletAddress])

	const goHome = useCallback(
		(error?: string) => {
			const state: PosHomeLocationState = error ? { homeActionError: error } : {}
			navigate(POS_HOME_ROUTES.home, { replace: true, state })
		},
		[navigate],
	)

	const onAmountContinue = useCallback(
		(input: { subtotal: string; methodRaw: ChargePaymentMethodRaw }) => {
			const infra = merchantInfraCard?.trim() ?? ''
			if (!infra) {
				goHome('Terminal program card is not configured.')
				return
			}
			setDraft({ subtotal: input.subtotal, methodRaw: input.methodRaw, tipBps: 0 })
			setPhase('tip')
		},
		[merchantInfraCard, goHome],
	)

	const startUsdcChargeFlow = useCallback(
		async (chargeDraft: ChargeDraft) => {
			if (!walletAddress) {
				goHome('Wallet not initialized')
				return
			}
			setPhase('executing')
			const prepared = await prepareUsdcChargeQr({
				subtotal: Number(chargeDraft.subtotal) || 0,
				tipBps: chargeDraft.tipBps,
				merchantInfraCard: merchantInfraCard?.trim() ?? '',
				posWallet: walletAddress,
				paymentMethodRaw: chargeDraft.methodRaw,
			})
			if (!prepared.ok) {
				goHome(prepared.message)
				return
			}
			setUsdcSid(prepared.sid)
			setUsdcPrepared({
				total: prepared.total,
				currency: prepared.currency,
				taxBps: prepared.taxBps,
			})
			setUsdcDeepLink(prepared.deepLink)
			setUsdcHint(usdcChargeCustomerHint(chargeDraft.methodRaw))
			setUsdcProgress('')
			setPhase('usdc-qr')
		},
		[walletAddress, merchantInfraCard, goHome],
	)

	const onTipConfirm = useCallback(
		(tipBps: number) => {
			if (!draft) return
			const next = { ...draft, tipBps }
			setDraft(next)
			if (isExternalWalletStablecoinMethod(next.methodRaw)) {
				void startUsdcChargeFlow(next)
				return
			}
			scanStartedRef.current = false
			setPhase('scan-customer')
		},
		[draft, startUsdcChargeFlow],
	)

	const resetCardSelection = useCallback(() => {
		adminBalanceReqRef.current += 1
		setPendingCustomer(null)
		setAdminCardAddresses([])
		setAdminCardRows([])
		setSelectedChargeCard('')
		setAdminCardsLoading(false)
		setSelectConfirming(false)
	}, [])

	const loadAdminCardBalances = useCallback(
		async (customer: ChargePendingCustomer, cards: string[]) => {
			const req = ++adminBalanceReqRef.current
			setAdminCardsLoading(true)
			const rows = await fetchChargeAdminCardBalances({ cards, customer })
			if (req !== adminBalanceReqRef.current) return
			setAdminCardRows(rows)
			setSelectedChargeCard(
				pickDefaultChargeAdminCard(rows, currency, merchantInfraCard ?? undefined),
			)
			setAdminCardsLoading(false)
		},
		[currency, merchantInfraCard],
	)

	const runNfcCharge = useCallback(
		async (
			uid: string,
			sun: { e: string; c: string; m: string } | undefined,
			chargeCardAddress?: string,
		) => {
			if (!draft || !walletAddress) {
				goHome('Wallet not initialized')
				return
			}
			const chargeCard = (chargeCardAddress ?? merchantInfraCard)?.trim() ?? ''
			if (!chargeCard) {
				goHome('Terminal program card is not configured.')
				return
			}
			setPhase('executing')
			setRoutingSteps(makeInitialPaymentRoutingSteps())
			const outcome = await executeNfcCharge({
				target: { uid, sun },
				subtotal: Number(draft.subtotal) || 0,
				tipBps: draft.tipBps,
				merchantInfraCard: chargeCard,
				posWallet: walletAddress,
				chargePolicy: POS_TERMINAL_CHARGE_POLICY_ALL,
				pointSystemEnabled,
				onRoutingStep: patchRoutingStep,
			})
			if (outcome.status === 'success') {
				setSuccess(outcome.result)
				setPhase('success')
				void refreshHome()
				return
			}
			if (outcome.status === 'insufficient') {
				setInsufficient({
					message: outcome.message,
					requiredLabel: outcome.requiredLabel,
					availableLabel: outcome.availableLabel,
				})
				setPhase('insufficient')
				return
			}
			goHome(outcome.message)
		},
		[draft, walletAddress, merchantInfraCard, goHome, refreshHome, pointSystemEnabled, patchRoutingStep],
	)

	const runQrCharge = useCallback(
		async (openContainerPayload: Record<string, unknown>, chargeCardAddress?: string) => {
			if (!draft || !walletAddress) {
				goHome('Wallet not initialized')
				return
			}
			const chargeCard = (chargeCardAddress ?? merchantInfraCard)?.trim() ?? ''
			if (!chargeCard) {
				goHome('Terminal program card is not configured.')
				return
			}
			setPhase('executing')
			setRoutingSteps(makeInitialPaymentRoutingSteps())
			const outcome = await executeQrCharge({
				openContainerPayload,
				subtotal: Number(draft.subtotal) || 0,
				tipBps: draft.tipBps,
				merchantInfraCard: chargeCard,
				posWallet: walletAddress,
				chargePolicy: POS_TERMINAL_CHARGE_POLICY_ALL,
				pointSystemEnabled,
				onRoutingStep: patchRoutingStep,
			})
			if (outcome.status === 'success') {
				setSuccess(outcome.result)
				setPhase('success')
				void refreshHome()
				return
			}
			if (outcome.status === 'insufficient') {
				setInsufficient({
					message: outcome.message,
					requiredLabel: outcome.requiredLabel,
					availableLabel: outcome.availableLabel,
				})
				setPhase('insufficient')
				return
			}
			goHome(outcome.message)
		},
		[draft, walletAddress, merchantInfraCard, goHome, refreshHome, pointSystemEnabled, patchRoutingStep],
	)

	const beginChargeAfterScan = useCallback(
		async (customer: ChargePendingCustomer, cancelled: () => boolean) => {
			if (!walletAddress) {
				goHome('Wallet not initialized')
				return
			}
			const cards = await resolvePosAdminMerchantCards({
				wallet: walletAddress,
				activeCard: merchantInfraCard?.trim() ?? '',
				bindings: workspaceBindings,
			})
			if (cancelled()) return
			if (cards.length <= 1) {
				const chargeCard = cards[0] ?? merchantInfraCard?.trim() ?? ''
				if (customer.kind === 'nfc') {
					await runNfcCharge(customer.uid, customer.sun, chargeCard)
					return
				}
				await runQrCharge(customer.payload, chargeCard)
				return
			}
			setPendingCustomer(customer)
			setAdminCardAddresses(cards)
			setAdminCardRows([])
			setSelectedChargeCard('')
			setSelectConfirming(false)
			setPhase('select-card')
			await loadAdminCardBalances(customer, cards)
		},
		[
			walletAddress,
			merchantInfraCard,
			workspaceBindings,
			goHome,
			runNfcCharge,
			runQrCharge,
			loadAdminCardBalances,
		],
	)

	const onSelectCardConfirm = useCallback(async () => {
		if (!pendingCustomer || !selectedChargeCard || selectConfirming) return
		setSelectConfirming(true)
		try {
			if (pendingCustomer.kind === 'nfc') {
				await runNfcCharge(pendingCustomer.uid, pendingCustomer.sun, selectedChargeCard)
				return
			}
			await runQrCharge(pendingCustomer.payload, selectedChargeCard)
		} finally {
			setSelectConfirming(false)
		}
	}, [pendingCustomer, selectedChargeCard, selectConfirming, runNfcCharge, runQrCharge])

	const onSelectCardBack = useCallback(() => {
		if (selectConfirming) return
		resetCardSelection()
		scanStartedRef.current = false
		setPhase('tip')
	}, [selectConfirming, resetCardSelection])

	const onSelectCardRetry = useCallback(() => {
		if (!pendingCustomer || adminCardAddresses.length === 0) return
		void loadAdminCardBalances(pendingCustomer, adminCardAddresses)
	}, [pendingCustomer, adminCardAddresses, loadAdminCardBalances])

	useEffect(() => {
		if (phase !== 'scan-customer') return
		if (scanStartedRef.current) return
		scanStartedRef.current = true

		let cancelled = false
		void (async () => {
			const scan = await runPosChargeScanFlow()
			if (cancelled) return

			if (scan.status === 'aborted') {
				goHome()
				return
			}
			if (scan.status === 'error') {
				goHome(scan.message)
				return
			}

			if (scan.status === 'nfc') {
				const uid = (scan.detail.queryUid ?? scan.detail.tagUidHex ?? '').trim()
				if (!uid || !scan.detail.sun) {
					goHome('Cannot read UID from this card.')
					return
				}
				await beginChargeAfterScan({ kind: 'nfc', uid, sun: scan.detail.sun }, () => cancelled)
				return
			}

			await beginChargeAfterScan({ kind: 'qr', payload: scan.payload }, () => cancelled)
		})()

		return () => {
			cancelled = true
			cancelPosCustomerScan()
		}
	}, [phase, goHome, beginChargeAfterScan])

	useEffect(() => {
		if (phase !== 'usdc-qr' || !usdcSid) return
		pollAbortRef.current?.abort()
		const ac = new AbortController()
		pollAbortRef.current = ac

		void (async () => {
			const outcome = await pollUsdcChargeSession({
				sid: usdcSid,
				signal: ac.signal,
				onProgress: setUsdcProgress,
			})
			if (ac.signal.aborted) return
			if (outcome.status === 'success') {
				const subtotal = draft?.subtotal ?? '0'
				const tipBps = draft?.tipBps ?? 0
				const subtotalNum = Number(subtotal) || 0
				const tipAmt = chargeTipFromRequestAndBps(subtotalNum, tipBps)
				const taxPercent = (usdcPrepared?.taxBps ?? 0) / 100
				const total =
					outcome.total ??
					usdcPrepared?.total?.toFixed(2) ??
					subtotal
				setSuccess({
					amount: total,
					subtotal,
					tip: tipAmt > 0 ? tipAmt.toFixed(2) : undefined,
					txHash: outcome.txHash,
					postBalance: '—',
					cardCurrency: usdcPrepared?.currency ?? 'CAD',
					payee: walletAddress ?? '',
					chargeTaxPercent: taxPercent,
					chargeTierDiscountPercent: 0,
					settlementViaQr: true,
					cardName: programCardName || undefined,
				})
				setPhase('success')
				void refreshHome()
				return
			}
			if (outcome.status === 'timeout') {
				goHome('USDC charge timed out.')
				return
			}
			goHome(outcome.message)
		})()

		return () => {
			ac.abort()
		}
	}, [phase, usdcSid, draft, walletAddress, usdcPrepared, programCardName, goHome, refreshHome])

	if (phase === 'amount') {
		return (
			<ChargeAmountPadPage
				programCardDisplayName={programCardName}
				currency={currency}
				onCancel={() => goHome()}
				onContinue={onAmountContinue}
			/>
		)
	}

	if (phase === 'tip' && draft) {
		return (
			<ChargeTipPage
				subtotal={draft.subtotal}
				onBack={() => setPhase('amount')}
				onConfirm={onTipConfirm}
			/>
		)
	}

	if (phase === 'select-card' && draft) {
		return (
			<ChargeSelectProgramCardPage
				billAmount={draft.subtotal}
				billCurrency={currency}
				rows={adminCardRows}
				loading={adminCardsLoading}
				selectedAddress={selectedChargeCard}
				confirming={selectConfirming}
				onSelect={setSelectedChargeCard}
				onConfirm={() => void onSelectCardConfirm()}
				onRetry={onSelectCardRetry}
				onBack={onSelectCardBack}
			/>
		)
	}

	if (phase === 'scan-customer') {
		return (
			<PosFlowLoadingShell
				title="Charge"
				subtitle="Waiting for NFC or QR scan…"
				bg="bg-[#f2f2f7]"
			/>
		)
	}

	if (phase === 'executing') {
		if (draft && !isExternalWalletStablecoinMethod(draft.methodRaw)) {
			return (
				<PosScanExecutingShell
					title="Charge"
					center={<PosPaymentRoutingMonitorCard steps={routingSteps} />}
				/>
			)
		}
		return (
			<PosFlowLoadingShell
				title="Charge"
				subtitle="Preparing USDC payment…"
				bg="bg-[#f2f2f7]"
			/>
		)
	}

	if (phase === 'usdc-qr' && usdcDeepLink) {
		return (
			<TopupUsdcQrPanel
				deepLink={usdcDeepLink}
				hint={usdcHint}
				progressLabel={usdcProgress || undefined}
				onCancel={() => {
					pollAbortRef.current?.abort()
					goHome()
				}}
			/>
		)
	}

	if (phase === 'success' && success) {
		return <ChargeSuccessView result={success} onDone={() => goHome()} />
	}

	if (phase === 'insufficient' && insufficient) {
		return (
			<ChargeInsufficientFundsView
				message={insufficient.message}
				requiredLabel={insufficient.requiredLabel}
				availableLabel={insufficient.availableLabel}
				onDone={() => goHome()}
			/>
		)
	}

	return <PosFlowLoadingShell title="Charge" subtitle="Loading…" />
}
