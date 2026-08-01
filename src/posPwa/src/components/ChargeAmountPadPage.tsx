import { CreditCard, Wallet } from 'lucide-react'
import { useMemo, useState } from 'react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { BeamioAmountPad, formatAmountPadDisplay } from '@/components/BeamioAmountPad'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { UsdcBaseCompositeIcon } from '@/components/ChainTokenCompositeIcon'
import {
	allowedChargeMethods,
	chargeOptionToMethodRaw,
	loadPersistedChargeMethod,
	savePersistedChargeMethod,
	type ChargePaymentMethodOption,
	type ChargePaymentMethodRaw,
	type PosTerminalChargePolicy,
	POS_TERMINAL_CHARGE_POLICY_ALL,
} from '@/utils/chargePaymentMethod'

const CHARGE_BLUE = '#1562f0'
const METHOD_ACCENT: Record<ChargePaymentMethodOption, string> = {
	credit: '#1562f0',
	usdc: '#2775CA',
	cadd: '#E53A2F',
}

export function ChargeAmountPadPage({
	policy = POS_TERMINAL_CHARGE_POLICY_ALL,
	programCardDisplayName = '',
	onCancel,
	onContinue,
}: {
	policy?: PosTerminalChargePolicy
	programCardDisplayName?: string
	onCancel: () => void
	onContinue: (input: { subtotal: string; methodRaw: ChargePaymentMethodRaw }) => void
}) {
	const allowed = useMemo(() => allowedChargeMethods(policy), [policy])
	const [methodOption, setMethodOption] = useState<ChargePaymentMethodOption>(() => {
		const saved = loadPersistedChargeMethod()
		return allowed.includes(saved) ? saved : (allowed[0] ?? 'credit')
	})
	const [amount, setAmount] = useState('0')

	const nextMethod = useMemo(() => {
		if (!allowed.length) return methodOption
		const idx = allowed.indexOf(methodOption)
		return allowed[(idx + 1) % allowed.length]
	}, [allowed, methodOption])

	const parsed = Number(amount)
	const canContinue = allowed.length > 0 && Number.isFinite(parsed) && parsed > 0
	const accent = METHOD_ACCENT[methodOption]
	const methodTitle =
		methodOption === 'credit'
			? programCardDisplayName.trim() || 'Beamio'
			: methodOption === 'usdc'
				? 'USDC'
				: 'CADD'

	return (
		<PosScreenShell bg="bg-[#EEF5FF]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onCancel}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="px-4 pb-[max(1rem,env(safe-area-inset-bottom))] pt-14">
					<div className="flex min-h-0 flex-1 flex-col gap-3">
						<div className="shrink-0 rounded-2xl bg-white p-4 shadow-sm">
							<div className="flex items-center gap-3">
								<div className="min-w-0 flex-1">
									<div className="flex items-baseline gap-1">
										<span className="text-3xl font-bold" style={{ color: accent }}>
											$
										</span>
										<span
											className="truncate text-5xl font-black tabular-nums"
											style={{ color: accent }}
										>
											{formatAmountPadDisplay(amount)}
										</span>
									</div>
								</div>
								<button
									type="button"
									onClick={() => {
										if (allowed.length <= 1) return
										setMethodOption(nextMethod)
										savePersistedChargeMethod(nextMethod)
									}}
									className="flex shrink-0 flex-col items-center gap-2"
									aria-label={`Payment method ${methodTitle}. Tap to switch`}
								>
									<span
										className="max-w-[5.5rem] truncate text-xs font-semibold"
										style={{ color: METHOD_ACCENT[methodOption] }}
									>
										{methodTitle}
									</span>
									<span
										className="flex h-11 w-11 items-center justify-center rounded-full"
										style={{ backgroundColor: `${METHOD_ACCENT[methodOption]}24` }}
									>
										{methodOption === 'usdc' ? (
											<UsdcBaseCompositeIcon size={22} />
										) : methodOption === 'cadd' ? (
											<Wallet className="h-5 w-5" style={{ color: METHOD_ACCENT.cadd }} />
										) : (
											<CreditCard className="h-5 w-5" style={{ color: accent }} />
										)}
									</span>
								</button>
							</div>
						</div>

						<BeamioAmountPad amount={amount} onAmountChange={setAmount} />

						<button
							type="button"
							disabled={!canContinue}
							onClick={() => {
								savePersistedChargeMethod(methodOption)
								onContinue({
									subtotal: amount,
									methodRaw: chargeOptionToMethodRaw(methodOption),
								})
							}}
							className="shrink-0 rounded-xl py-4 text-lg font-semibold text-white disabled:opacity-45"
							style={{ backgroundColor: CHARGE_BLUE }}
						>
							Continue
						</button>
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
