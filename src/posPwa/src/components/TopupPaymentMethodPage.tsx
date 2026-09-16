import { Banknote, Check, CreditCard, Sparkles, Wallet } from 'lucide-react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { StripeIcon } from '@/components/StripeIcon'
import { UsdcBaseCompositeIcon } from '@/components/ChainTokenCompositeIcon'
import {
	allowedTopupMethods,
	loadPersistedTopupMethod,
	savePersistedTopupMethod,
	TOPUP_METHOD_LABEL,
	type PosTerminalTopupPolicy,
	type TopupPaymentMethodRaw,
} from '@/utils/topupPaymentMethod'

const METHOD_ACCENT: Record<TopupPaymentMethodRaw, string> = {
	creditCard: '#D49B1F',
	stripePhysicalCard: '#635BFF',
	usdc: '#2775CA',
	cadd: '#E53A2F',
	cash: '#6B7280',
	bonus: '#EC4899',
}

function methodIcon(method: TopupPaymentMethodRaw) {
	switch (method) {
		case 'creditCard':
			return CreditCard
		case 'cash':
			return Banknote
		case 'bonus':
			return Sparkles
		default:
			return Wallet
	}
}

function MethodIcon({ method }: { method: TopupPaymentMethodRaw }) {
	if (method === 'usdc') return <UsdcBaseCompositeIcon size={30} />
	if (method === 'stripePhysicalCard') return <StripeIcon size={30} />
	const Icon = methodIcon(method)
	return <Icon className="h-7 w-7" style={{ color: METHOD_ACCENT[method] }} aria-hidden />
}

export function TopupPaymentMethodPage({
	policy,
	onCancel,
	onSelect,
}: {
	policy: PosTerminalTopupPolicy
	onCancel: () => void
	onSelect: (method: TopupPaymentMethodRaw) => void
}) {
	const methods = allowedTopupMethods(policy)
	const lastMethod = loadPersistedTopupMethod()
	const orderedMethods = methods.includes(lastMethod)
		? [lastMethod, ...methods.filter((method) => method !== lastMethod)]
		: methods

	return (
		<PosScreenShell bg="bg-[#F9F9FE]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onCancel}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="overflow-y-auto px-4 pb-[max(1rem,env(safe-area-inset-bottom))] pt-16">
					<div className="mx-auto flex w-full max-w-xl flex-col gap-4">
						<div>
							<p className="text-xs font-bold uppercase tracking-[0.2em] text-[#7C3AED]">
								Top-up
							</p>
							<h1 className="mt-1 text-3xl font-black text-slate-900">
								Select payment method
							</h1>
							<p className="mt-2 text-sm text-slate-500">
								Choose a method before entering the top-up amount.
							</p>
						</div>
						<div className="grid grid-cols-2 gap-3">
							{orderedMethods.map((method) => {
								const selected = method === lastMethod
								const accent = METHOD_ACCENT[method]
								return (
									<button
										key={method}
										type="button"
										onClick={() => {
											savePersistedTopupMethod(method)
											onSelect(method)
										}}
										className="relative flex min-h-32 flex-col items-center justify-center gap-3 rounded-2xl border-2 bg-white p-4 text-center shadow-sm transition active:scale-[0.98]"
										style={{
											borderColor: selected ? accent : `${accent}45`,
											backgroundColor: selected ? `${accent}10` : '#fff',
										}}
										aria-label={`Use ${TOPUP_METHOD_LABEL[method]}`}
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
											{TOPUP_METHOD_LABEL[method]}
										</span>
									</button>
								)
							})}
						</div>
						{methods.length === 0 ? (
							<p className="rounded-2xl bg-white p-4 text-sm text-slate-600 shadow-sm">
								No top-up methods are enabled for this terminal.
							</p>
						) : null}
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
