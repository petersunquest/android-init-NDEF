import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { DeductPointsAmountPadPage } from '@/components/DeductPointsAmountPadPage'
import { DeductPointsSuccessView } from '@/components/DeductPointsSuccessView'
import { PosFlowLoadingShell } from '@/components/PosFlowLoadingShell'
import { PosScanExecutingShell } from '@/components/PosScanExecutingShell'
import { PosTopupExecutingCard } from '@/components/PosTopupExecutingCard'
import { usePosSession } from '@/providers/PosSessionProvider'
import {
	executeDeductPoints,
	type DeductCustomerTarget,
	type DeductExecuteProgressPhase,
	type DeductExecuteSuccess,
} from '@/utils/deductPointsExecute'
import { cancelPosCustomerScan, runPosCustomerScanFlow } from '@/utils/posScanFlow'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import type { PosHomeLocationState } from '@/utils/posHomeLocationState'

type DeductPhase = 'amount' | 'scan-customer' | 'executing' | 'success'

function customerTargetFromScan(
	scan:
		| { status: 'nfc'; detail: { queryUid?: string; tagUidHex?: string; sun?: { e: string; c: string; m: string } } }
		| { status: 'qr'; identity: { beamioTag?: string; wallet?: string } },
): DeductCustomerTarget | null {
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
 * iOS-aligned Deduct Points: amount pad → NFC/QR → burn prepare + sign + submit → success.
 */
export function DeductPointsPage() {
	const navigate = useNavigate()
	const { merchantInfraCard, pointSystemEnabled, refreshHome } = usePosSession()

	const [phase, setPhase] = useState<DeductPhase>('amount')
	const [keypadAmount, setKeypadAmount] = useState('')
	const [success, setSuccess] = useState<DeductExecuteSuccess | null>(null)
	const [deductProgress, setDeductProgress] = useState<DeductExecuteProgressPhase>('preparing')
	const scanStartedRef = useRef(false)

	const goHome = useCallback(
		(error?: string) => {
			const state: PosHomeLocationState = error ? { homeActionError: error } : {}
			navigate(POS_HOME_ROUTES.home, { replace: true, state })
		},
		[navigate],
	)

	const runDeduct = useCallback(
		async (target: DeductCustomerTarget, viaQr: boolean) => {
			const infra = merchantInfraCard?.trim() ?? ''
			if (!infra) {
				goHome('Merchant program card is unavailable.')
				return
			}
			setDeductProgress('preparing')
			setPhase('executing')
			const outcome = await executeDeductPoints({
				target,
				keypadAmount,
				merchantInfraCard: infra,
				pointSystemEnabled,
				viaQr,
				onProgress: setDeductProgress,
			})
			if (outcome.status === 'success') {
				setSuccess(outcome.result)
				setPhase('success')
				void refreshHome()
				return
			}
			goHome(outcome.message)
		},
		[keypadAmount, merchantInfraCard, pointSystemEnabled, goHome, refreshHome],
	)

	useEffect(() => {
		if (phase !== 'scan-customer') return
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
						? 'Card does not support SUN. Cannot deduct points.'
						: 'Cannot parse customer identity.',
				)
				return
			}
			await runDeduct(target, scan.status === 'qr')
		})()

		return () => {
			cancelled = true
			cancelPosCustomerScan()
		}
	}, [phase, goHome, runDeduct])

	useEffect(() => {
		return () => cancelPosCustomerScan()
	}, [])

	if (phase === 'amount') {
		return (
			<DeductPointsAmountPadPage
				onCancel={() => goHome()}
				onContinue={(amount) => {
					setKeypadAmount(amount)
					scanStartedRef.current = false
					setPhase('scan-customer')
				}}
			/>
		)
	}

	if (phase === 'success' && success) {
		return (
			<DeductPointsSuccessView
				result={success}
				pointSystemEnabled={pointSystemEnabled}
				onDone={() => navigate(POS_HOME_ROUTES.home, { replace: true })}
			/>
		)
	}

	if (phase === 'executing') {
		const pts = Number(keypadAmount.replace(/,/g, '')) || 0
		return (
			<PosScanExecutingShell
				title="Deduct Points"
				center={
					<PosTopupExecutingCard signingInProgress={deductProgress === 'signing'} />
				}
				bottomAmount={pts > 0 ? pts : undefined}
				bottomTone="deduct"
			/>
		)
	}

	if (phase === 'scan-customer') {
		return (
			<PosFlowLoadingShell
				title="Deduct Points"
				subtitle="Waiting for NFC or QR scan…"
				bg="bg-[#f2f2f7]"
			/>
		)
	}

	return (
		<PosFlowLoadingShell title="Deduct Points" subtitle="Loading…" bg="bg-[#f2f2f7]" />
	)
}
