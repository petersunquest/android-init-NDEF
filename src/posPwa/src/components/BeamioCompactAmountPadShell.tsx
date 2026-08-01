import { useEffect, useRef, useState, type ReactNode } from 'react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenShell } from '@/components/PosScreenShell'

const AMOUNT_PAD_BG = '#EEF5FF'

/** iOS `BoxWithConstraintsLikeChargeAmountPad` layout metrics. */
function useAmountPadLayoutMetrics() {
	const ref = useRef<HTMLDivElement>(null)
	const [metrics, setMetrics] = useState({
		compact: false,
		sidePad: 20,
		gap: 10,
		amountPx: 64,
		bottomPad: 20,
	})

	useEffect(() => {
		const el = ref.current
		if (!el) return
		const measure = () => {
			const compact = el.getBoundingClientRect().height < 640
			setMetrics({
				compact,
				sidePad: compact ? 16 : 20,
				gap: compact ? 8 : 10,
				amountPx: compact ? 52 : 64,
				bottomPad: compact ? 12 : 20,
			})
		}
		measure()
		const ro = new ResizeObserver(measure)
		ro.observe(el)
		return () => ro.disconnect()
	}, [])

	return { ref, ...metrics }
}

/**
 * Shared amount-pad chrome — iOS `BoxWithConstraintsLikeChargeAmountPad`.
 * Used by Deduct Points (no payment method row).
 */
export function BeamioCompactAmountPadShell({
	accent,
	title,
	continueTitle = 'Continue',
	amountDisplay,
	aboveAmountDisplay,
	belowAmountHint,
	canContinue,
	onCancel,
	onContinue,
	keypad,
}: {
	accent: string
	title: string
	continueTitle?: string
	amountDisplay: ReactNode
	/** e.g. available pts balance below title. */
	aboveAmountDisplay?: ReactNode
	/** e.g. validation hint under the amount. */
	belowAmountHint?: ReactNode
	canContinue: boolean
	onCancel: () => void
	onContinue: () => void
	keypad: ReactNode
}) {
	const { ref, sidePad, gap, amountPx, bottomPad } = useAmountPadLayoutMetrics()

	return (
		<PosScreenShell bg="bg-[#EEF5FF]" className="text-slate-900">
			<div ref={ref} className="flex min-h-0 flex-1 flex-col">
				<div
					className="grid shrink-0 grid-cols-[36px_1fr_36px] items-center pt-[max(6px,env(safe-area-inset-top))]"
					style={{
						paddingLeft: sidePad,
						paddingRight: sidePad,
						paddingBottom: gap,
					}}
				>
					<BeamioCircularBackButton onClick={onCancel} />
					<h1 className="pointer-events-none text-center text-[17px] font-semibold leading-tight">
						{title}
					</h1>
					<div className="h-9 w-9" aria-hidden />
				</div>

				{aboveAmountDisplay ? (
					<div
						className="shrink-0 text-center"
						style={{ paddingLeft: sidePad, paddingRight: sidePad, paddingBottom: gap }}
					>
						{aboveAmountDisplay}
					</div>
				) : null}

				<div
					className="shrink-0 text-center font-black tabular-nums leading-none"
					style={{
						color: accent,
						fontSize: amountPx,
						paddingTop: gap,
						paddingBottom: gap,
					}}
				>
					{amountDisplay}
				</div>

				{belowAmountHint ? (
					<p
						className="shrink-0 text-center text-sm font-medium text-amber-600"
						style={{ paddingBottom: gap }}
					>
						{belowAmountHint}
					</p>
				) : null}

				<div
					className="flex min-h-0 flex-1 flex-col"
					style={{ paddingLeft: sidePad, paddingRight: sidePad }}
				>
					{keypad}
				</div>

				<div
					className="shrink-0"
					style={{
						paddingLeft: sidePad,
						paddingRight: sidePad,
						paddingTop: 8,
						paddingBottom: `max(${bottomPad}px, env(safe-area-inset-bottom))`,
					}}
				>
					<button
						type="button"
						disabled={!canContinue}
						onClick={onContinue}
						className="flex h-[52px] w-full items-center justify-center rounded-full text-base font-bold text-white transition-opacity disabled:pointer-events-none"
						style={{
							backgroundColor: accent,
							opacity: canContinue ? 1 : 0.45,
						}}
					>
						{continueTitle}
					</button>
				</div>
			</div>
		</PosScreenShell>
	)
}

export { AMOUNT_PAD_BG }
