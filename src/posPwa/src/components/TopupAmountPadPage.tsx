import {
	Banknote,
	CreditCard,
	Sparkles,
	Wallet,
} from 'lucide-react'
import { useMemo, useState } from 'react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { BeamioAmountPad, formatAmountPadDisplay } from '@/components/BeamioAmountPad'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { UsdcBaseCompositeIcon } from '@/components/ChainTokenCompositeIcon'
import { nfcTopupCurrencySplitFromPosKeypad } from '@/utils/topupCurrencySplit'
import {
	allowedTopupMethods,
	loadPersistedTopupMethod,
	savePersistedTopupMethod,
	TOPUP_METHOD_LABEL,
	type TopupPaymentMethodRaw,
	type PosTerminalTopupPolicy,
	POS_TERMINAL_TOPUP_POLICY_ALL,
} from '@/utils/topupPaymentMethod'
import { MEMBERSHIP_FEE_CHECK_BALANCE_HINT } from '@/utils/readBalanceMembership'

const TOPUP_PURPLE = '#7C3AED'
const METHOD_ACCENT: Record<TopupPaymentMethodRaw, string> = {
	creditCard: '#D49B1F',
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

export function TopupAmountPadPage({
	policy = POS_TERMINAL_TOPUP_POLICY_ALL,
	membershipRequired = false,
	cardCurrencyPrefix = '$',
	onCancel,
	onContinue,
}: {
	policy?: PosTerminalTopupPolicy
	/** A confirmed customer without a valid membership — direct staff to Check Balance. */
	membershipRequired?: boolean
	cardCurrencyPrefix?: string
	onCancel: () => void
	onContinue: (input: {
		method: TopupPaymentMethodRaw
		keypadAmount: string
		currencyAmount: string
	}) => void
}) {
	const allowed = useMemo(() => allowedTopupMethods(policy), [policy])

	const [method, setMethod] = useState<TopupPaymentMethodRaw>(() => {
		const saved = loadPersistedTopupMethod()
		return allowed.includes(saved) ? saved : (allowed[0] ?? 'creditCard')
	})
	const [amount, setAmount] = useState('0')

	const nextMethod = useMemo(() => {
		if (!allowed.length) return method
		const idx = allowed.indexOf(method)
		return allowed[(idx + 1) % allowed.length]
	}, [allowed, method])

	const parsed = Number(amount)
	const canContinue =
		!membershipRequired &&
		allowed.length > 0 &&
		Number.isFinite(parsed) &&
		parsed > 0
	const accent = method === 'bonus' ? METHOD_ACCENT.bonus : TOPUP_PURPLE

	return (
		<PosScreenShell bg="bg-[#F9F9FE]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onCancel}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="px-4 pb-[max(1rem,env(safe-area-inset-bottom))] pt-14">
					<div className="flex min-h-0 flex-1 flex-col gap-3">
						{membershipRequired ? (
							<div className="shrink-0 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
								<p className="font-semibold">Membership required</p>
								<p className="mt-1 leading-snug">{MEMBERSHIP_FEE_CHECK_BALANCE_HINT}</p>
							</div>
						) : null}

						<div className="shrink-0 rounded-2xl bg-white p-4 shadow-sm">
							<div className="flex items-center gap-3">
								<div className="min-w-0 flex-1">
									<div className="flex items-baseline gap-1">
										<span
											className="text-3xl font-bold"
											style={{ color: accent }}
										>
											{cardCurrencyPrefix}
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
									disabled={membershipRequired}
									onClick={() => {
										if (membershipRequired || allowed.length <= 1) return
										setMethod(nextMethod)
										savePersistedTopupMethod(nextMethod)
									}}
									className="flex shrink-0 flex-col items-center gap-2 disabled:opacity-45"
									aria-label={`Payment method ${TOPUP_METHOD_LABEL[method]}. Tap to switch`}
								>
									<span
										className="text-xs font-semibold"
										style={{ color: METHOD_ACCENT[method] }}
									>
										{TOPUP_METHOD_LABEL[method]}
									</span>
									<span
										className="flex h-11 w-11 items-center justify-center rounded-full"
										style={{ backgroundColor: `${METHOD_ACCENT[method]}24` }}
									>
										{method === 'usdc' ? (
											<UsdcBaseCompositeIcon size={22} />
										) : (
											(() => {
												const Icon = methodIcon(method)
												return (
													<Icon
														className="h-5 w-5"
														style={{ color: METHOD_ACCENT[method] }}
													/>
												)
											})()
										)}
									</span>
								</button>
							</div>
						</div>

						{allowed.length === 0 ? (
							<p className="shrink-0 text-sm font-medium text-slate-600">
								No top-up methods are enabled for this terminal. Ask the merchant to
								update device settings.
							</p>
						) : null}

						<BeamioAmountPad
							amount={amount}
							onAmountChange={membershipRequired ? () => {} : setAmount}
						/>

						<button
							type="button"
							disabled={!canContinue}
							onClick={() => {
								const split = nfcTopupCurrencySplitFromPosKeypad(
									amount,
									method,
									false,
									20,
								)
								if (!split) return
								savePersistedTopupMethod(method)
								onContinue({
									method,
									keypadAmount: amount,
									currencyAmount: split.currencyAmount,
								})
							}}
							className="shrink-0 rounded-xl py-4 text-lg font-semibold text-white disabled:opacity-45"
							style={{ backgroundColor: TOPUP_PURPLE }}
						>
							Confirm Top-Up
						</button>
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
