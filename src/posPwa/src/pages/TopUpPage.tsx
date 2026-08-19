import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
	fetchCardCurrencyCode,
	fetchCardMetadataRoot,
	fetchCardMetadataTiersBundle,
	fetchCardOwner,
} from '@/api/beamioApi'
import { metadataTiersHaveMembershipFee } from '@/utils/beamioPaymentRouting'
import { displayFiatPrefixFromCode } from '@/utils/display'
import { PosFlowLoadingShell } from '@/components/PosFlowLoadingShell'
import { PosScanExecutingShell } from '@/components/PosScanExecutingShell'
import { PosTopupExecutingCard } from '@/components/PosTopupExecutingCard'
import { TopupAmountPadPage } from '@/components/TopupAmountPadPage'
import { TopupSuccessView } from '@/components/TopupSuccessView'
import { TopupUsdcQrPanel } from '@/components/TopupUsdcQrPanel'
import { usePosSession } from '@/providers/PosSessionProvider'
import {
	parseRechargeBonusRulesFromMetadata,
	resolveTopupApiAmountAndSplit,
} from '@/utils/programRechargeBonus'
import { cancelPosCustomerScan, runPosCustomerScanFlow } from '@/utils/posScanFlow'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import type { PosHomeLocationState } from '@/utils/posHomeLocationState'
import {
	executeNfcTopup,
	type TopupCustomerTarget,
	type TopupExecuteProgressPhase,
	type TopupExecuteSuccess,
} from '@/utils/topupExecute'
import {
	isExternalWalletStablecoinMethod,
	type TopupPaymentMethodRaw,
} from '@/utils/topupPaymentMethod'
import type { NfcTopupCurrencySplit } from '@/utils/topupCurrencySplit'
import {
	buildUsdcTopupQrUrlPhase1,
	buildUsdcTopupQrUrlWithNfc,
	newTopupUsdcSessionId,
	pollUsdcTopupSession,
	usdcTopupCustomerHint,
} from '@/utils/topupUsdcSession'

type TopUpPhase =
	| 'amount'
	| 'scan-customer'
	| 'executing'
	| 'usdc-qr'
	| 'scan-nfc-after-usdc'
	| 'success'

interface TopupDraft {
	method: TopupPaymentMethodRaw
	keypadAmount: string
	currencyAmount: string
	apiAmount: string
	split: NfcTopupCurrencySplit | null
	membershipTierIndex?: number
	membershipFeeFiat6?: string
}

function customerTargetFromScan(
	scan:
		| { status: 'nfc'; detail: { queryUid?: string; tagUidHex?: string; sun?: { e: string; c: string; m: string } } }
		| { status: 'qr'; identity: { beamioTag?: string; wallet?: string } },
): TopupCustomerTarget | null {
	if (scan.status === 'nfc') {
		const uid = (scan.detail.queryUid ?? scan.detail.tagUidHex ?? '').trim()
		if (!uid || !scan.detail.sun) return null
		return { uid, sun: scan.detail.sun }
	}
	if (scan.identity.beamioTag?.trim()) {
		return { beamioTag: scan.identity.beamioTag.trim() }
	}
	if (scan.identity.wallet) {
		return { wallet: scan.identity.wallet }
	}
	return null
}

/**
 * iOS-aligned Top-up: amount pad → NFC/QR → (USDC QR + poll) → sign & execute → success.
 */
export function TopUpPage() {
	const navigate = useNavigate()
	const { merchantInfraCard, walletAddress, refreshHome, pointSystemEnabled } = usePosSession()

	const [phase, setPhase] = useState<TopUpPhase>('amount')
	const [draft, setDraft] = useState<TopupDraft | null>(null)
	const [customer, setCustomer] = useState<TopupCustomerTarget | null>(null)
	const [success, setSuccess] = useState<TopupExecuteSuccess | null>(null)
	const [usdcDeepLink, setUsdcDeepLink] = useState('')
	const [usdcHint, setUsdcHint] = useState('')
	const [usdcProgress, setUsdcProgress] = useState('')
	const [usdcSid, setUsdcSid] = useState('')
	const pollAbortRef = useRef<AbortController | null>(null)
	const scanStartedRef = useRef(false)
	const [topupProgress, setTopupProgress] = useState<TopupExecuteProgressPhase>('preparing')
	const [membershipFeeMode, setMembershipFeeMode] = useState(false)
	const [cardCurrencyPrefix, setCardCurrencyPrefix] = useState('$')

	useEffect(() => {
		const infra = merchantInfraCard?.trim() ?? ''
		if (!infra) return
		let cancelled = false
		void (async () => {
			const [tiersBundle, currency] = await Promise.all([
				fetchCardMetadataTiersBundle(infra),
				fetchCardCurrencyCode(infra),
			])
			if (cancelled) return
			setMembershipFeeMode(metadataTiersHaveMembershipFee(tiersBundle.rows))
			setCardCurrencyPrefix(displayFiatPrefixFromCode(currency ?? 'CAD', 'CAD'))
		})()
		return () => {
			cancelled = true
		}
	}, [merchantInfraCard])

	const goHome = useCallback(
		(error?: string) => {
			const state: PosHomeLocationState = error ? { homeActionError: error } : {}
			navigate(POS_HOME_ROUTES.home, { replace: true, state })
		},
		[navigate],
	)

	const onAmountContinue = useCallback(
		async (input: {
			method: TopupPaymentMethodRaw
			keypadAmount: string
			currencyAmount: string
		}) => {
			const infra = merchantInfraCard?.trim() ?? ''
			if (!infra) {
				goHome('Terminal program card is not configured.')
				return
			}
			const metaRoot = await fetchCardMetadataRoot(infra)
			const rules = parseRechargeBonusRulesFromMetadata(metaRoot?.metadata ?? null)
			const resolved = resolveTopupApiAmountAndSplit({
				keypadAmount: input.keypadAmount,
				methodRaw: input.method,
				bonusExpanded: false,
				bonusRatePercent: 20,
				programRules: rules,
			})
			setDraft({
				method: input.method,
				keypadAmount: input.keypadAmount,
				currencyAmount: input.currencyAmount,
				apiAmount: resolved.apiAmount,
				split: resolved.split,
			})
			scanStartedRef.current = false
			setPhase('scan-customer')
		},
		[merchantInfraCard, goHome],
	)

	const runCardTopup = useCallback(
		async (target: TopupCustomerTarget, sid?: string) => {
			if (!draft || !walletAddress) {
				goHome('Wallet not initialized')
				return
			}
			setTopupProgress('preparing')
			setPhase('executing')
			const outcome = await executeNfcTopup({
				target,
				apiAmount: draft.apiAmount,
				currencySplit: draft.split,
				merchantInfraCard: merchantInfraCard?.trim() ?? '',
				posWallet: walletAddress,
				usdcTopupSessionId: sid,
				pointSystemEnabled,
				membershipTierIndex: draft.membershipTierIndex,
				membershipFeeFiat6: draft.membershipFeeFiat6,
				onProgress: setTopupProgress,
			})
			if (outcome.status === 'success') {
				setSuccess(outcome.result)
				setPhase('success')
				void refreshHome()
				return
			}
			goHome(outcome.message)
		},
		[draft, walletAddress, merchantInfraCard, goHome, refreshHome, pointSystemEnabled],
	)

	const startUsdcQrFlow = useCallback(
		async (target: TopupCustomerTarget, fromQrCustomer: boolean) => {
			if (!draft || !walletAddress) {
				goHome('Wallet not initialized')
				return
			}
			const infra = merchantInfraCard?.trim() ?? ''
			const owner = await fetchCardOwner(infra, walletAddress)
			if (!owner) {
				goHome('Cannot resolve card owner. Please retry.')
				return
			}
			const currency = (await fetchCardCurrencyCode(infra)) ?? 'CAD'
			const sid = newTopupUsdcSessionId()
			setUsdcSid(sid)
			let link = ''
			if (target.uid && target.sun) {
				link = buildUsdcTopupQrUrlWithNfc({
					cardAddress: infra,
					cardOwner: owner,
					uid: target.uid,
					sun: target.sun,
					amount: draft.apiAmount,
					currency,
					sid,
					pos: walletAddress,
					paymentMethodRaw: draft.method,
				})
			} else {
				link = buildUsdcTopupQrUrlPhase1({
					cardAddress: infra,
					cardOwner: owner,
					amount: draft.apiAmount,
					currency,
					sid,
					pos: walletAddress,
					paymentMethodRaw: draft.method,
				})
			}
			setUsdcDeepLink(link)
			setUsdcHint(
				usdcTopupCustomerHint(
					draft.method,
					fromQrCustomer || Boolean(target.beamioTag || target.wallet),
				),
			)
			setUsdcProgress('')
			setCustomer(target)
			setPhase('usdc-qr')
		},
		[draft, walletAddress, merchantInfraCard, goHome],
	)

	useEffect(() => {
		if (phase !== 'scan-customer' && phase !== 'scan-nfc-after-usdc') return
		if (scanStartedRef.current) return
		scanStartedRef.current = true

		let cancelled = false
		void (async () => {
			const scan = await runPosCustomerScanFlow()
			if (cancelled) return

			if (scan.status === 'aborted') {
				goHome()
				return
			}
			if (scan.status === 'error') {
				goHome(scan.message)
				return
			}

			const target = customerTargetFromScan(scan)
			if (!target) {
				goHome(
					scan.status === 'nfc'
						? 'Card does not support SUN. Cannot top up.'
						: 'Cannot parse customer identity.',
				)
				return
			}
			setCustomer(target)

			if (phase === 'scan-nfc-after-usdc') {
				await runCardTopup(target, usdcSid)
				return
			}

			if (draft && isExternalWalletStablecoinMethod(draft.method)) {
				await startUsdcQrFlow(target, scan.status === 'qr')
				return
			}

			await runCardTopup(target)
		})()

		return () => {
			cancelled = true
			cancelPosCustomerScan()
		}
	}, [phase, draft, goHome, runCardTopup, startUsdcQrFlow, usdcSid])

	useEffect(() => {
		if (phase !== 'usdc-qr' || !usdcSid) return
		pollAbortRef.current?.abort()
		const ac = new AbortController()
		pollAbortRef.current = ac

		void (async () => {
			const outcome = await pollUsdcTopupSession({
				sid: usdcSid,
				signal: ac.signal,
				onProgress: setUsdcProgress,
			})
			if (ac.signal.aborted) return

			if (outcome.status === 'success') {
				setSuccess({
					amount: draft?.apiAmount ?? '',
					txHash: outcome.txHash,
					preBalance: '—',
					postBalance: '—',
					cardCurrency: 'CAD',
					settlementViaQr: true,
				})
				setPhase('success')
				void refreshHome()
				return
			}
			if (outcome.status === 'timeout') {
				goHome('USDC top-up timed out.')
				return
			}
			if (outcome.status === 'error') {
				goHome(outcome.message)
				return
			}
			if (outcome.status === 'awaiting_beneficiary') {
				if (customer?.beamioTag || customer?.wallet) {
					await runCardTopup(customer, usdcSid)
					return
				}
				scanStartedRef.current = false
				setPhase('scan-nfc-after-usdc')
			}
		})()

		return () => {
			ac.abort()
		}
	}, [phase, usdcSid, customer, draft, goHome, runCardTopup, refreshHome])

	useEffect(() => {
		return () => {
			pollAbortRef.current?.abort()
			cancelPosCustomerScan()
		}
	}, [])

	if (phase === 'amount') {
		return (
			<TopupAmountPadPage
				membershipFeeMode={membershipFeeMode}
				cardCurrencyPrefix={cardCurrencyPrefix}
				onCancel={() => goHome()}
				onContinue={(input) => void onAmountContinue(input)}
			/>
		)
	}

	if (phase === 'success' && success) {
		return (
			<TopupSuccessView
				result={success}
				onDone={() => navigate(POS_HOME_ROUTES.home, { replace: true })}
			/>
		)
	}

	if (phase === 'usdc-qr' && usdcDeepLink) {
		return (
			<TopupUsdcQrPanel
				deepLink={usdcDeepLink}
				hint={usdcHint}
				progressLabel={usdcProgress}
				onCancel={() => goHome()}
			/>
		)
	}

	if (phase === 'executing' && draft) {
		const totalCredit = Number(draft.split?.currencyAmount ?? draft.apiAmount) || 0
		const bonusCredit = Number(draft.split?.bonusCurrencyAmount ?? 0) || 0
		const keypadAmount = Number(draft.currencyAmount ?? draft.keypadAmount) || 0
		return (
			<PosScanExecutingShell
				title="Top-up"
				center={
					<PosTopupExecutingCard
						signingInProgress={topupProgress === 'signing'}
						totalCredit={totalCredit > 0 ? totalCredit : undefined}
						bonusCredit={bonusCredit > 1e-6 ? bonusCredit : undefined}
					/>
				}
				bottomAmount={keypadAmount > 0 ? keypadAmount : totalCredit}
				bottomBonus={bonusCredit > 1e-6 ? bonusCredit : undefined}
				bottomTone="topup"
			/>
		)
	}

	if (phase === 'scan-customer' || phase === 'scan-nfc-after-usdc') {
		return (
			<PosFlowLoadingShell
				title="Top-up"
				subtitle={
					phase === 'scan-nfc-after-usdc'
						? 'USDC paid. Tap customer NFC card…'
						: 'Waiting for NFC or QR scan…'
				}
				bg="bg-[#f2f2f7]"
			/>
		)
	}

	return (
		<PosFlowLoadingShell title="Top-up" subtitle="Loading…" bg="bg-[#f2f2f7]" />
	)
}
