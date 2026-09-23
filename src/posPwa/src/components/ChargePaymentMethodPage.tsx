import { Check, CreditCard, Smartphone, Wallet } from 'lucide-react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { UsdcBaseCompositeIcon } from '@/components/ChainTokenCompositeIcon'
import {
	allowedChargeMethods,
	CHARGE_METHOD_LABEL,
	loadPersistedChargeMethod,
	savePersistedChargeMethod,
	type ChargePaymentMethodOption,
	type PosTerminalChargePolicy,
} from '@/utils/chargePaymentMethod'

const METHOD_ACCENT: Record<ChargePaymentMethodOption, string> = {
	credit: '#1562F0',
	usdc: '#2775CA',
	cadd: '#E53A2F',
	tapToPay: '#635BFF',
}

function MethodIcon({ method }: { method: ChargePaymentMethodOption }) {
	if (method === 'usdc') return <UsdcBaseCompositeIcon size={30} />
	if (method === 'cadd') {
		return <Wallet className="h-7 w-7" style={{ color: METHOD_ACCENT.cadd }} aria-hidden />
	}
	if (method === 'tapToPay') {
		return <Smartphone className="h-7 w-7" style={{ color: METHOD_ACCENT.tapToPay }} aria-hidden />
	}
	return <CreditCard className="h-7 w-7" style={{ color: METHOD_ACCENT.credit }} aria-hidden />
}

export function ChargePaymentMethodPage({
	policy,
	onCancel,
	onSelect,
}: {
	policy: PosTerminalChargePolicy
	onCancel: () => void
	onSelect: (method: ChargePaymentMethodOption) => void
}) {
	const methods = allowedChargeMethods(policy)
	const lastMethod = loadPersistedChargeMethod()
	const orderedMethods = methods.includes(lastMethod)
		? [lastMethod, ...methods.filter((method) => method !== lastMethod)]
		: methods

	return (
		<PosScreenShell bg="bg-[#EEF5FF]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onCancel}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="overflow-y-auto px-4 pb-[max(1rem,env(safe-area-inset-bottom))] pt-16">
					<div className="mx-auto flex w-full max-w-xl flex-col gap-4">
						<div>
							<p className="text-xs font-bold uppercase tracking-[0.2em] text-[#1562F0]">
								Charge
							</p>
							<h1 className="mt-1 text-3xl font-black text-slate-900">
								Select payment method
							</h1>
							<p className="mt-2 text-sm text-slate-500">
								Choose a method before entering the charge amount.
							</p>
						</div>
						<div className="grid grid-cols-2 gap-3">
							{orderedMethods.map((method) => {
								const accent = METHOD_ACCENT[method]
								const selected = method === lastMethod
								return (
									<button
										key={method}
										type="button"
										onClick={() => {
											savePersistedChargeMethod(method)
											onSelect(method)
										}}
										className="relative flex min-h-32 flex-col items-center justify-center gap-3 rounded-2xl border-2 bg-white p-4 text-center shadow-sm transition active:scale-[0.98]"
										style={{
											borderColor: selected ? accent : `${accent}45`,
											backgroundColor: selected ? `${accent}10` : '#fff',
										}}
										aria-label={`Use ${CHARGE_METHOD_LABEL[method]}`}
									>
										{selected ? (
											<span
												className="absolute right-2 top-2 flex h-5 w-5 items-center justify-center rounded-full text-white"
												style={{ backgroundColor: accent }}
											>
												<Check className="h-3.5 w-3.5" aria-hidden />
											</span>
										) : null}
										<span
											className="flex h-14 w-14 items-center justify-center rounded-full"
											style={{ backgroundColor: `${accent}20` }}
										>
											<MethodIcon method={method} />
										</span>
										<span className="text-sm font-bold" style={{ color: accent }}>
											{CHARGE_METHOD_LABEL[method]}
										</span>
									</button>
								)
							})}
						</div>
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
