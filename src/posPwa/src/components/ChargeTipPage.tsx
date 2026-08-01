import { ChevronRight } from 'lucide-react'
import { useMemo, useState } from 'react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'

const CHARGE_BLUE = '#1562f0'

function sanitizeTipInput(raw: string): string {
	let s = raw.replace(/,/g, '').replace(/[^\d.]/g, '')
	const parts = s.split('.')
	if (parts.length > 2) s = `${parts[0]}.${parts.slice(1).join('')}`
	if (parts.length === 2 && parts[1].length > 2) {
		s = `${parts[0]}.${parts[1].slice(0, 2)}`
	}
	return s
}

type TipMode = { kind: 'percent'; rate: number } | { kind: 'custom' }

/** iOS `TipFlowPage` — 15% / 18% / 20% or custom tip → bps. */
export function ChargeTipPage({
	subtotal,
	onBack,
	onConfirm,
}: {
	subtotal: string
	onBack: () => void
	onConfirm: (tipBps: number) => void
}) {
	const num = Number(subtotal) || 0
	const [mode, setMode] = useState<TipMode>({ kind: 'percent', rate: 0.15 })
	const [customTipText, setCustomTipText] = useState('')
	const [customVisible, setCustomVisible] = useState(false)

	const confirmTipBps = useMemo(() => {
		if (mode.kind === 'percent') {
			const r = Math.min(1, Math.max(0, mode.rate))
			return Math.round(r * 10_000)
		}
		const t = customTipText.trim()
		const v = Number(t)
		if (!(v >= 0) || !(num > 0)) return 0
		return Math.min(10_000, Math.max(0, Math.round((v / num) * 10_000)))
	}, [mode, customTipText, num])

	return (
		<PosScreenShell bg="bg-[#EEF5FF]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onBack}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="px-4 pb-[max(1rem,env(safe-area-inset-bottom))] pt-14">
					<div className="flex min-h-0 flex-1 flex-col items-center gap-5 pt-4">
						<p className="text-sm text-slate-500">Subtotal</p>
						<p className="text-5xl font-light tabular-nums text-slate-900">
							${num.toFixed(2)}
						</p>

						{!(mode.kind === 'custom' && customVisible) ? (
							<div className="grid w-full max-w-md grid-cols-2 gap-4">
								{([0.15, 0.18, 0.2] as const).map((rate) => {
									const selected = mode.kind === 'percent' && mode.rate === rate
									const label = `${Math.round(rate * 100)}%`
									return (
										<button
											key={rate}
											type="button"
											onClick={() => {
												setMode({ kind: 'percent', rate })
												setCustomVisible(false)
											}}
											className={`rounded-2xl border py-5 text-lg font-semibold ${
												selected
													? 'border-brand-blue bg-white text-brand-blue shadow-sm'
													: 'border-slate-200 bg-white text-slate-700'
											}`}
										>
											{label}
										</button>
									)
								})}
								<button
									type="button"
									onClick={() => {
										setMode({ kind: 'custom' })
										setCustomVisible(true)
									}}
									className={`rounded-2xl border py-5 text-lg font-semibold ${
										mode.kind === 'custom'
											? 'border-brand-blue bg-white text-brand-blue shadow-sm'
											: 'border-slate-200 bg-white text-slate-700'
									}`}
								>
									Custom
								</button>
							</div>
						) : null}

						{mode.kind === 'custom' && customVisible ? (
							<div className="flex w-full max-w-md items-center gap-2 rounded-2xl border border-slate-200 bg-white px-4 py-4">
								<span className="text-xl font-semibold" style={{ color: CHARGE_BLUE }}>
									$
								</span>
								<input
									type="text"
									inputMode="decimal"
									autoComplete="off"
									enterKeyHint="done"
									value={customTipText}
									onChange={(e) => setCustomTipText(sanitizeTipInput(e.target.value))}
									placeholder="0.00"
									className="min-w-0 flex-1 bg-transparent text-xl font-semibold tabular-nums outline-none"
									autoFocus
								/>
							</div>
						) : null}

						<button
							type="button"
							onClick={() => onConfirm(confirmTipBps)}
							className="mt-auto flex w-full max-w-md items-center justify-center gap-2 rounded-xl py-4 text-lg font-semibold text-white"
							style={{ backgroundColor: CHARGE_BLUE }}
						>
							Confirm & Pay
							<ChevronRight className="h-5 w-5" aria-hidden />
						</button>
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
