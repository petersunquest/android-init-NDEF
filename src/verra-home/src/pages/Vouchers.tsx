import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { SiteHeader } from '../components/SiteHeader'

const BEAMIO_API = 'https://beamio.app'
const BASE_USDC_TOKEN_ADDRESS = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'

type PrecheckResponse = {
	success?: boolean
	error?: string
	payee?: string
	amount?: string
	currency?: string
	paymentUrl?: string
}

const addrShort = (v: string): string => (v.length > 14 ? `${v.slice(0, 8)}…${v.slice(-6)}` : v)

function parseAmountToAtomic6(amount: string): string | null {
	if (!/^\d+(?:\.\d{1,6})?$/.test(amount)) return null
	const [i, f = ''] = amount.split('.')
	const frac = `${f}000000`.slice(0, 6)
	try {
		const val = BigInt(i) * 1_000_000n + BigInt(frac)
		if (val <= 0n) return null
		return val.toString()
	} catch {
		return null
	}
}

export function Vouchers() {
	const [sp] = useSearchParams()
	const [loading, setLoading] = useState(true)
	const [precheckError, setPrecheckError] = useState('')
	const [precheckOk, setPrecheckOk] = useState(false)

	const amount = useMemo(() => {
		const v = (sp.get('Amount') ?? sp.get('amount') ?? '').trim()
		return v
	}, [sp])
	const to = useMemo(() => (sp.get('to') ?? '').trim(), [sp])
	const currency = useMemo(() => (sp.get('currency') ?? 'USDC').trim().toUpperCase(), [sp])
	const acceptTokens = useMemo(() => (sp.get('acceptTokens') ?? sp.get('accepttokens') ?? 'USDC').trim().toUpperCase(), [sp])

	const isValidAddress = /^0x[0-9a-fA-F]{40}$/.test(to)
	const atomic6 = useMemo(() => parseAmountToAtomic6(amount), [amount])
	const eip681Url = useMemo(() => {
		if (!isValidAddress || !atomic6) return ''
		return `ethereum:${BASE_USDC_TOKEN_ADDRESS}@8453/transfer?address=${to}&uint256=${atomic6}`
	}, [atomic6, isValidAddress, to])

	const queryError = useMemo(() => {
		if (!isValidAddress) return 'Missing or invalid `to` address in URL.'
		if (!amount || !atomic6) return 'Missing or invalid `Amount` in URL.'
		if (currency !== 'USDC') return 'Only USDC payment links are supported here.'
		if (!acceptTokens.split(',').map((s) => s.trim()).includes('USDC')) return '`acceptTokens` must include USDC.'
		return ''
	}, [acceptTokens, amount, atomic6, currency, isValidAddress])

	useEffect(() => {
		if (queryError) {
			setLoading(false)
			setPrecheckOk(false)
			setPrecheckError(queryError)
			return
		}
		let alive = true
		setLoading(true)
		setPrecheckError('')
		const q = new URLSearchParams({
			to,
			amount,
			currency: 'USDC',
			acceptTokens: 'USDC',
		})
		void fetch(`${BEAMIO_API}/api/vouchersReceivePreCheck?${q.toString()}`)
			.then(async (r) => {
				const j = (await r.json()) as PrecheckResponse
				if (!alive) return
				setPrecheckOk(Boolean(j.success))
				if (!j.success) setPrecheckError(j.error ?? 'Precheck failed')
			})
			.catch(() => {
				if (!alive) return
				setPrecheckOk(false)
				setPrecheckError('Failed to contact precheck API.')
			})
			.finally(() => {
				if (alive) setLoading(false)
			})
		return () => {
			alive = false
		}
	}, [amount, queryError, to])

	return (
		<div className="min-h-screen bg-slate-950 text-slate-100">
			<SiteHeader />
			<main className="mx-auto w-full max-w-2xl px-4 py-8">
				<div className="rounded-2xl border border-slate-800 bg-slate-900/70 p-6">
					<h1 className="text-2xl font-extrabold tracking-tight">Pay USDC on Base</h1>
					<p className="mt-2 text-sm text-slate-300">This payment link sends USDC directly to the merchant EOA.</p>
					<div className="mt-5 space-y-2 text-sm">
						<div className="flex items-center justify-between gap-2">
							<span className="text-slate-400">Recipient</span>
							<span className="font-mono">{isValidAddress ? addrShort(to) : 'Invalid'}</span>
						</div>
						<div className="flex items-center justify-between gap-2">
							<span className="text-slate-400">Amount</span>
							<span className="font-semibold">{amount || 'Invalid'} USDC</span>
						</div>
					</div>

					{loading ? <p className="mt-5 text-sm text-slate-300">Checking receiver B-Unit status…</p> : null}
					{precheckError ? (
						<div className="mt-5 rounded-lg border border-amber-400/40 bg-amber-500/10 p-3 text-sm text-amber-200">{precheckError}</div>
					) : null}
					{!loading && precheckOk ? (
						<div className="mt-5 rounded-lg border border-emerald-400/40 bg-emerald-500/10 p-3 text-sm text-emerald-200">
							Receiver precheck passed. You can continue with third-party wallet payment.
						</div>
					) : null}

					<div className="mt-5 space-y-3">
						<a
							href={eip681Url || '#'}
							onClick={(e) => {
								if (!eip681Url || loading || !!precheckError) e.preventDefault()
							}}
							className={`inline-flex w-full items-center justify-center rounded-xl px-4 py-3 text-sm font-bold ${
								eip681Url && !loading && !precheckError
									? 'bg-blue-600 text-white hover:bg-blue-500'
									: 'cursor-not-allowed bg-slate-800 text-slate-500'
							}`}
						>
							Open Wallet Payment
						</a>
						{eip681Url ? (
							<button
								type="button"
								onClick={() => void navigator.clipboard.writeText(eip681Url)}
								className="w-full rounded-xl border border-slate-700 px-4 py-2 text-xs font-semibold text-slate-200 hover:bg-slate-800"
							>
								Copy EIP-681 URL
							</button>
						) : null}
					</div>

					<p className="mt-4 text-xs text-slate-400">Only send USDC on Base chain. Other tokens or networks may be lost.</p>
				</div>
			</main>
		</div>
	)
}
