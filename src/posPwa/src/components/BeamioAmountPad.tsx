import { Delete } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'

function appendDigit(current: string, digit: string): string {
	if (digit === '.' && current.includes('.')) return current
	if (current === '0' && digit !== '.') return digit
	if (current.includes('.') && digit !== '.') {
		const [, frac = ''] = current.split('.')
		if (frac.length >= 2) return current
	}
	return current + digit
}

export function formatAmountPadDisplay(amount: string): string {
	const n = Number(amount)
	if (!Number.isFinite(n)) return '0'
	if (amount.includes('.')) {
		const [whole, frac = ''] = amount.split('.')
		const wholeNum = Number(whole)
		const wholeFmt = Number.isFinite(wholeNum)
			? wholeNum.toLocaleString('en-US')
			: whole
		return frac.length ? `${wholeFmt}.${frac}` : wholeFmt
	}
	return n.toLocaleString('en-US')
}

/** iOS `BeamioNumericAmountPadKeypad` rows. */
const KEYPAD_ROWS = [
	['1', '2', '3'],
	['4', '5', '6'],
	['7', '8', '9'],
	['.', '0', '⌫'],
] as const

/** iOS: `max(16, min(approxKeyW, cellH) * (compact ? 0.4 : 0.42))` */
function keypadFontSize(width: number, height: number, compact: boolean): number {
	const colGap = compact ? 7 : 9
	const rowGap = compact ? 7 : 9
	const rowCount = KEYPAD_ROWS.length
	const cellH = rowCount > 0 ? Math.max(1, (height - (rowCount - 1) * rowGap) / rowCount) : 1
	const approxKeyW = Math.max(0, (width - 2 * colGap) / 3)
	return Math.max(16, Math.min(approxKeyW, cellH) * (compact ? 0.4 : 0.42))
}

export function BeamioAmountPad({
	amount,
	onAmountChange,
	compact: compactOverride,
}: {
	amount: string
	onAmountChange: (next: string) => void
	/** When omitted, compact follows container height (<640px), same as iOS GeometryReader. */
	compact?: boolean
}) {
	const containerRef = useRef<HTMLDivElement>(null)
	const [size, setSize] = useState({ w: 0, h: 0 })

	useEffect(() => {
		const el = containerRef.current
		if (!el) return
		const measure = () => {
			const { width, height } = el.getBoundingClientRect()
			setSize({ w: width, h: height })
		}
		measure()
		const ro = new ResizeObserver(measure)
		ro.observe(el)
		return () => ro.disconnect()
	}, [])

	const compact = compactOverride ?? size.h < 640
	const colGap = compact ? 7 : 9
	const rowGap = compact ? 7 : 9
	const fontSize = keypadFontSize(size.w, size.h, compact)

	function onKey(key: string) {
		if (key === '⌫') {
			const next = amount.length <= 1 ? '0' : amount.slice(0, -1)
			onAmountChange(next || '0')
			return
		}
		onAmountChange(appendDigit(amount, key))
	}

	return (
		<div
			ref={containerRef}
			className="flex min-h-0 flex-1 flex-col"
			style={{ gap: rowGap }}
		>
			{KEYPAD_ROWS.map((row) => (
				<div
					key={row.join('-')}
					className="flex min-h-0 flex-1"
					style={{ gap: colGap }}
				>
					{row.map((key) => (
						<button
							key={key}
							type="button"
							onClick={() => onKey(key)}
							className="flex min-h-0 min-w-0 flex-1 items-center justify-center rounded-[14px] border border-black/[0.06] bg-white font-medium text-slate-900 active:bg-slate-50"
							style={{
								fontSize,
								fontFamily:
									'ui-rounded, "SF Pro Rounded", "SF Pro Display", system-ui, sans-serif',
							}}
						>
							{key === '⌫' ? (
								<Delete
									strokeWidth={2}
									style={{ width: fontSize, height: fontSize }}
									aria-hidden
								/>
							) : (
								key
							)}
						</button>
					))}
				</div>
			))}
		</div>
	)
}
