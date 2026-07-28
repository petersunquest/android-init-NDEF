import { Loader2 } from 'lucide-react'
import {
	paymentRoutingStepsForDisplay,
	type PaymentRoutingStep,
} from '@/utils/paymentRoutingSteps'

const SCREEN_BG = '#0f1419'
const BEZEL = '#3d4553'
const LINE_OK = '#8ae06c'
const LINE_PENDING = '#5c6b5c'

/** iOS `PaymentRoutingMonitorCard` / Android `PaymentRoutingMonitorDisplayCard`. */
export function PosPaymentRoutingMonitorCard({
	steps,
	errorLine,
	retryHint,
	onRetryTap,
	className = '',
}: {
	steps: PaymentRoutingStep[]
	errorLine?: string
	retryHint?: string
	onRetryTap?: () => void
	className?: string
}) {
	const visible = paymentRoutingStepsForDisplay(steps)

	return (
		<div
			className={`relative h-[280px] w-[280px] overflow-hidden rounded-[2rem] border-2 ${className}`.trim()}
			style={{ backgroundColor: SCREEN_BG, borderColor: BEZEL }}
			role={onRetryTap && errorLine ? 'button' : undefined}
			tabIndex={onRetryTap && errorLine ? 0 : undefined}
			onClick={() => {
				if (onRetryTap && errorLine) onRetryTap()
			}}
			onKeyDown={(e) => {
				if (!onRetryTap || !errorLine) return
				if (e.key === 'Enter' || e.key === ' ') {
					e.preventDefault()
					onRetryTap()
				}
			}}
		>
			<div className="flex h-full flex-col justify-end p-2.5">
				<div className="w-full space-y-0.5">
					{visible.map((step) => (
						<PaymentRoutingRow key={step.id} step={step} />
					))}
				</div>
				{errorLine ? (
					<p
						className="mt-1.5 font-mono text-[10px] leading-tight"
						style={{ color: '#ff6b6b' }}
					>
						{errorLine}
					</p>
				) : null}
				{errorLine && retryHint ? (
					<p
						className="mt-1.5 text-center font-mono text-[9px]"
						style={{ color: '#7c8a99' }}
					>
						{retryHint}
					</p>
				) : null}
			</div>
		</div>
	)
}

function PaymentRoutingRow({ step }: { step: PaymentRoutingStep }) {
	const line = step.detail ? `${step.label} ${step.detail}` : step.label
	const textColor =
		step.status === 'error'
			? '#ffb4a8'
			: step.status === 'pending'
				? LINE_PENDING
				: LINE_OK

	return (
		<div className="flex items-center gap-1.5 py-0.5">
			<div className="flex w-4 shrink-0 items-center justify-center">
				{step.status === 'loading' ? (
					<Loader2 className="h-3 w-3 animate-spin" style={{ color: LINE_OK }} aria-hidden />
				) : step.status === 'success' ? (
					<span className="font-mono text-[8px]" style={{ color: LINE_OK }}>
						OK
					</span>
				) : step.status === 'error' ? (
					<span className="font-mono text-[8px]" style={{ color: '#ff8980' }}>
						NO
					</span>
				) : (
					<span className="font-mono text-[8px]" style={{ color: LINE_PENDING }}>
						--
					</span>
				)}
			</div>
			<p className="line-clamp-2 flex-1 font-mono text-[10px] leading-tight" style={{ color: textColor }}>
				{line}
			</p>
		</div>
	)
}
