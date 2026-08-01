export type PaymentRoutingStepStatus = 'pending' | 'loading' | 'success' | 'error'

export interface PaymentRoutingStep {
	id: string
	label: string
	detail: string
	status: PaymentRoutingStepStatus
}

export type PaymentRoutingStepPatch = (
	id: string,
	status: PaymentRoutingStepStatus,
	detail?: string,
) => void

/** iOS `makeInitialPaymentRoutingSteps` / Android payment screen routing steps. */
export function makeInitialPaymentRoutingSteps(): PaymentRoutingStep[] {
	return [
		{ id: 'detectingUser', label: 'Detecting User', detail: '', status: 'pending' },
		{ id: 'membership', label: 'Checking Membership', detail: '', status: 'pending' },
		{ id: 'analyzingAssets', label: 'Analyzing Assets', detail: '', status: 'pending' },
		{ id: 'optimizingRoute', label: 'Optimizing Route', detail: '', status: 'pending' },
		{ id: 'sendTx', label: 'Sending transaction', detail: '', status: 'pending' },
		{ id: 'waitTx', label: 'Waiting for transaction', detail: '', status: 'pending' },
		{ id: 'refreshBalance', label: 'Refreshing balance', detail: '', status: 'pending' },
	]
}

export function patchPaymentRoutingStep(
	steps: PaymentRoutingStep[],
	id: string,
	status: PaymentRoutingStepStatus,
	detail?: string,
): PaymentRoutingStep[] {
	return steps.map((row) => {
		if (row.id !== id) return row
		return {
			...row,
			status,
			detail: detail !== undefined && detail !== '' ? detail : row.detail,
		}
	})
}

/** iOS `beamioPaymentRoutingStepsForDisplay` — hide early pending rows, show last N. */
export function paymentRoutingStepsForDisplay(
	steps: PaymentRoutingStep[],
	maxVisible = 6,
): PaymentRoutingStep[] {
	const early = new Set(['detectingUser', 'membership', 'analyzingAssets', 'optimizingRoute'])
	const filtered = steps.filter(
		(step) => early.has(step.id) || step.status !== 'pending',
	)
	if (filtered.length <= maxVisible) return filtered
	return filtered.slice(-maxVisible)
}
