import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { createWalletClient, custom, type Address } from 'viem'
import { base } from 'viem/chains'
import { wrapFetchWithPayment, decodeXPaymentResponse } from 'x402-fetch'
import { SiteFooter } from '../components/SiteFooter'
import { SiteHeader } from '../components/SiteHeader'

declare global {
	interface Window {
		ethereum?: {
			request: (args: { method: string; params?: unknown[] | object }) => Promise<unknown>
			on?: (eventName: string, listener: (...args: unknown[]) => void) => void
			removeListener?: (eventName: string, listener: (...args: unknown[]) => void) => void
			isMetaMask?: boolean
		}
	}
}

const BEAMIO_API = 'https://beamio.app'
const BASE_CHAIN_ID_HEX = '0x2105'

type Status =
	| 'idle'
	| 'connecting'
	| 'switching-chain'
	| 'quoting'
	| 'awaiting-signature'
	| 'settling'
	| 'success'
	| 'error'

type QuoteResponse = {
	success?: boolean
	error?: string
	quotedUsdc6?: string
	quotedUsdc?: string
	currency?: string
	subtotal?: string
	discount?: string
	tax?: string
	tip?: string
	total?: string
	discountBps?: number
	taxBps?: number
	tipBps?: number
	cardOwner?: string
}

type ChargeParams = {
	cardAddress: string
	cardOwner: string
	uid: string
	e: string
	c: string
	m: string
	subtotal: string
	discount: string
	tax: string
	tip: string
	discountBps: string
	taxBps: string
	tipBps: string
	currency: string
}

const truncate = (s: string, head = 6, tail = 4): string =>
	s && s.length > head + tail + 3 ? `${s.slice(0, head)}…${s.slice(-tail)}` : s

const isHex = (s: string, len?: number): boolean =>
	typeof s === 'string' && /^[0-9a-fA-F]+$/.test(s) && (len === undefined || s.length === len)

const isEthAddress = (s: string): boolean => typeof s === 'string' && /^0x[0-9a-fA-F]{40}$/.test(s)

const numOrZero = (raw: string): number => {
	const n = Number((raw ?? '').toString().trim())
	return Number.isFinite(n) && n > 0 ? n : 0
}

/**
 * NFC 模式（兼容旧链路）：URL 同时带 `uid + e + c + m` ⇒ 后端走 SUN 校验。
 * 第三方钱包模式（iOS POS no-NFC USDC charge）：四个字段全部缺省 ⇒ 后端跳过 SUN，直接 x402 settle 给 cardOwner。
 * 任意一个 SUN 字段存在但不完整 ⇒ 视为坏链接（防止 partial param 误传到后端被 400）。
 */
function parseParams(sp: URLSearchParams): { ok: true; params: ChargeParams } | { ok: false; error: string } {
	const cardAddress = (sp.get('card') ?? '').trim()
	const cardOwner = (sp.get('owner') ?? '').trim()
	const uid = (sp.get('uid') ?? '').trim()
	const e = (sp.get('e') ?? '').trim()
	const c = (sp.get('c') ?? '').trim()
	const m = (sp.get('m') ?? '').trim()
	const subtotal = (sp.get('subtotal') ?? '').trim()
	const discount = (sp.get('discount') ?? '0').trim()
	const tax = (sp.get('tax') ?? '0').trim()
	const tip = (sp.get('tip') ?? '0').trim()
	const discountBps = (sp.get('discountBps') ?? '0').trim()
	const taxBps = (sp.get('taxBps') ?? '0').trim()
	const tipBps = (sp.get('tipBps') ?? '0').trim()
	const currency = (sp.get('currency') ?? 'CAD').trim().toUpperCase()
	if (!isEthAddress(cardAddress)) return { ok: false, error: 'Missing or invalid `card` (BeamioUserCard address)' }
	if (!isEthAddress(cardOwner)) return { ok: false, error: 'Missing or invalid `owner` (card owner EOA)' }
	const sunFieldsPresent = [uid, e, c, m].filter((v) => v.length > 0).length
	if (sunFieldsPresent > 0 && sunFieldsPresent < 4) {
		return { ok: false, error: 'Incomplete NFC SUN params (need all of `uid`, `e`, `c`, `m`, or none for third-party wallet payment)' }
	}
	if (sunFieldsPresent === 4) {
		if (!isHex(uid, 14)) return { ok: false, error: 'Invalid `uid` (NFC UID, 14 hex chars)' }
		if (!isHex(e, 64)) return { ok: false, error: 'Invalid SUN `e` (64 hex chars)' }
		if (!isHex(c, 6)) return { ok: false, error: 'Invalid SUN `c` (6 hex chars)' }
		if (!isHex(m, 16)) return { ok: false, error: 'Invalid SUN `m` (16 hex chars)' }
	}
	if (!subtotal || !(Number(subtotal) > 0)) return { ok: false, error: 'Missing or invalid `subtotal`' }
	if (!currency) return { ok: false, error: 'Missing `currency`' }
	const total = numOrZero(subtotal) - numOrZero(discount) + numOrZero(tax) + numOrZero(tip)
	if (!(total > 0)) return { ok: false, error: 'Invalid breakdown (total <= 0)' }
	return {
		ok: true,
		params: { cardAddress, cardOwner, uid, e, c, m, subtotal, discount, tax, tip, discountBps, taxBps, tipBps, currency },
	}
}

function formatCurrency(amount: string | number, currency: string): string {
	const n = typeof amount === 'number' ? amount : Number(amount)
	if (!Number.isFinite(n)) return `${currency} ${amount}`
	const decimals = currency === 'JPY' || currency === 'TWD' ? 0 : 2
	return `${currency} ${n.toFixed(decimals)}`
}

function formatUsdc(usdc6OrHuman: string | undefined): string {
	if (!usdc6OrHuman) return '—'
	if (usdc6OrHuman.includes('.')) return `${Number(usdc6OrHuman).toFixed(2)} USDC`
	const n = Number(usdc6OrHuman)
	if (!Number.isFinite(n)) return '— USDC'
	return `${(n / 1_000_000).toFixed(2)} USDC`
}

function buildMetamaskDeeplink(): string {
	const host = window.location.host
	const path = window.location.pathname
	const search = window.location.search
	return `https://metamask.app.link/dapp/${host}${path}${search}`
}

export function UsdcCharge() {
	const [sp] = useSearchParams()
	const parsed = useMemo(() => parseParams(sp), [sp])
	const [account, setAccount] = useState<Address | null>(null)
	const [chainIdHex, setChainIdHex] = useState<string | null>(null)
	const [quote, setQuote] = useState<QuoteResponse | null>(null)
	const [status, setStatus] = useState<Status>('idle')
	const [error, setError] = useState<string | null>(null)
	const [result, setResult] = useState<{ usdcTx?: string; settle?: unknown } | null>(null)

	const eth = typeof window !== 'undefined' ? window.ethereum : undefined

	useEffect(() => {
		if (!parsed.ok || !eth) return
		;(async () => {
			try {
				const chain = (await eth.request({ method: 'eth_chainId' })) as string
				setChainIdHex(chain)
				const accounts = (await eth.request({ method: 'eth_accounts' })) as string[]
				if (accounts && accounts[0]) setAccount(accounts[0] as Address)
			} catch {
				/* ignore */
			}
		})()
		const onAccounts = (accs: unknown) => {
			const list = accs as string[] | undefined
			setAccount(list && list[0] ? (list[0] as Address) : null)
		}
		const onChain = (chain: unknown) => setChainIdHex(typeof chain === 'string' ? chain : null)
		eth.on?.('accountsChanged', onAccounts as (...args: unknown[]) => void)
		eth.on?.('chainChanged', onChain as (...args: unknown[]) => void)
		return () => {
			eth.removeListener?.('accountsChanged', onAccounts as (...args: unknown[]) => void)
			eth.removeListener?.('chainChanged', onChain as (...args: unknown[]) => void)
		}
	}, [eth, parsed.ok])

	useEffect(() => {
		if (!parsed.ok) return
		const p = parsed.params
		setStatus((s) => (s === 'idle' ? 'quoting' : s))
		const q = new URLSearchParams({
			card: p.cardAddress,
			owner: p.cardOwner,
			subtotal: p.subtotal,
			discount: p.discount,
			tax: p.tax,
			tip: p.tip,
			discountBps: p.discountBps,
			taxBps: p.taxBps,
			tipBps: p.tipBps,
			currency: p.currency,
		}).toString()
		const url = `${BEAMIO_API}/api/nfcUsdcChargeQuote?${q}`
		fetch(url)
			.then(async (r) => {
				const json = (await r.json().catch(() => ({}))) as QuoteResponse
				if (!r.ok || json.success === false) {
					setError(json.error ?? 'Failed to fetch quote')
					setStatus('error')
					return
				}
				setQuote(json)
				setStatus('idle')
			})
			.catch((e) => {
				setError(e?.message ?? String(e))
				setStatus('error')
			})
	}, [
		parsed.ok ? parsed.params.cardAddress : '',
		parsed.ok ? parsed.params.cardOwner : '',
		parsed.ok ? parsed.params.subtotal : '',
		parsed.ok ? parsed.params.discount : '',
		parsed.ok ? parsed.params.tax : '',
		parsed.ok ? parsed.params.tip : '',
		parsed.ok ? parsed.params.currency : '',
	])

	const connectWallet = async () => {
		if (!eth) return
		setError(null)
		setStatus('connecting')
		try {
			const accounts = (await eth.request({ method: 'eth_requestAccounts' })) as string[]
			setAccount(accounts[0] as Address)
			const chain = (await eth.request({ method: 'eth_chainId' })) as string
			setChainIdHex(chain)
			setStatus('idle')
		} catch (e: unknown) {
			const msg = e instanceof Error ? e.message : String(e)
			setError(msg)
			setStatus('error')
		}
	}

	const switchToBase = async () => {
		if (!eth) return
		setError(null)
		setStatus('switching-chain')
		try {
			await eth.request({
				method: 'wallet_switchEthereumChain',
				params: [{ chainId: BASE_CHAIN_ID_HEX }],
			})
			setChainIdHex(BASE_CHAIN_ID_HEX)
			setStatus('idle')
		} catch (e: unknown) {
			const err = e as { code?: number; message?: string }
			if (err?.code === 4902) {
				try {
					await eth.request({
						method: 'wallet_addEthereumChain',
						params: [
							{
								chainId: BASE_CHAIN_ID_HEX,
								chainName: 'Base',
								nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
								rpcUrls: ['https://mainnet.base.org'],
								blockExplorerUrls: ['https://basescan.org'],
							},
						],
					})
					setChainIdHex(BASE_CHAIN_ID_HEX)
					setStatus('idle')
					return
				} catch (addErr: unknown) {
					const aMsg = addErr instanceof Error ? addErr.message : String(addErr)
					setError(aMsg)
					setStatus('error')
					return
				}
			}
			setError(err?.message ?? 'Failed to switch chain')
			setStatus('error')
		}
	}

	const payWithUsdc = async () => {
		if (!parsed.ok || !eth || !account) return
		setError(null)
		setStatus('awaiting-signature')
		setResult(null)
		try {
			const walletClient = createWalletClient({
				account,
				chain: base,
				transport: custom(eth),
			})
			const fetchWithPay = wrapFetchWithPayment(
				fetch,
				walletClient as unknown as Parameters<typeof wrapFetchWithPayment>[1],
				BigInt(1_000_000_000)
			)
			const body = JSON.stringify(parsed.params)
			const response = await fetchWithPay(`${BEAMIO_API}/api/nfcUsdcCharge`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body,
			})
			setStatus('settling')
			const json = (await response.json().catch(() => ({}))) as {
				success?: boolean
				error?: string
				USDC_tx?: string
			}
			const xPayResp = response.headers.get('x-payment-response')
			const decoded = xPayResp ? decodeXPaymentResponse(xPayResp) : null
			if (!response.ok || json.success === false) {
				setError(json.error ?? `Charge failed (HTTP ${response.status})`)
				setStatus('error')
				return
			}
			setResult({ usdcTx: json.USDC_tx, settle: decoded })
			setStatus('success')
		} catch (e: unknown) {
			const msg = e instanceof Error ? e.message : String(e)
			setError(msg)
			setStatus('error')
		}
	}

	if (!parsed.ok) {
		return (
			<div className="min-h-dvh bg-background text-on-surface antialiased">
				<SiteHeader />
				<main className="pt-24 pb-12">
					<div className="mx-auto max-w-xl px-6">
						<div className="rounded-2xl border border-rose-200 bg-rose-50 p-6 text-rose-800 dark:border-rose-800/50 dark:bg-rose-950/30 dark:text-rose-200">
							<h2 className="mb-2 text-xl font-bold">Invalid charge link</h2>
							<p className="text-sm leading-relaxed">{parsed.error}</p>
							<p className="mt-4 text-xs opacity-80">
								Required: <code>card</code>, <code>owner</code>, <code>subtotal</code>,{' '}
								<code>currency</code>. Optional: <code>discount</code>, <code>tax</code>,{' '}
								<code>tip</code>, <code>discountBps</code>, <code>taxBps</code>, <code>tipBps</code>.
								NFC SUN (<code>uid</code>+<code>e</code>+<code>c</code>+<code>m</code>) is optional —
								provide all four for NFC-bound charges, or none for pure third-party-wallet payment.
							</p>
						</div>
					</div>
				</main>
				<SiteFooter />
			</div>
		)
	}

	const { cardAddress, cardOwner, uid, currency } = parsed.params
	const hasNfcSun = uid.length > 0
	const onBase = chainIdHex?.toLowerCase() === BASE_CHAIN_ID_HEX
	const hasWallet = !!eth
	const ready = hasWallet && !!account && onBase

	const subtotalNum = numOrZero(parsed.params.subtotal)
	const discountNum = numOrZero(parsed.params.discount)
	const taxNum = numOrZero(parsed.params.tax)
	const tipNum = numOrZero(parsed.params.tip)
	const totalNum = Math.max(0, subtotalNum - discountNum + taxNum + tipNum)
	const quotedUsdcLabel = formatUsdc(quote?.quotedUsdc ?? quote?.quotedUsdc6)

	return (
		<div className="min-h-dvh bg-background text-on-surface antialiased">
			<SiteHeader />
			<main className="pt-24 pb-12">
				<div className="mx-auto max-w-xl px-6">
					<header className="mb-8 text-center">
						<h1 className="text-3xl font-extrabold tracking-tight">Pay with USDC</h1>
						<p className="mt-2 text-on-surface-variant">
							Settle this purchase with USDC on Base from your own wallet.
						</p>
					</header>

					<section className="rounded-3xl border border-outline-variant/20 bg-surface-container-lowest p-6 shadow-[0_4px_24px_rgba(0,0,0,0.04)]">
						<div className="grid grid-cols-1 gap-3 text-sm">
							<Row label="Subtotal" value={formatCurrency(subtotalNum, currency)} />
							{discountNum > 0 ? (
								<Row label="Discount" value={`− ${formatCurrency(discountNum, currency)}`} accent="rose" />
							) : null}
							{taxNum > 0 ? <Row label="Tax" value={formatCurrency(taxNum, currency)} /> : null}
							{tipNum > 0 ? <Row label="Tip" value={formatCurrency(tipNum, currency)} /> : null}
							<Divider />
							<Row label="Total" value={formatCurrency(totalNum, currency)} bold />
							<Row label="You pay" value={status === 'quoting' ? 'Quoting…' : quotedUsdcLabel} mono bold />
							<Divider />
							<Row label="Merchant (card owner)" value={truncate(cardOwner, 8, 6)} mono />
							<Row label="BeamioUserCard" value={truncate(cardAddress, 8, 6)} mono />
							{hasNfcSun ? (
								<Row label="NFC tag" value={`…${uid.slice(-6).toUpperCase()}`} mono />
							) : null}
							<Row label="Network" value="Base mainnet" mono={false} />
						</div>
					</section>

					<section className="mt-6">
						{!hasWallet ? (
							<NoWalletPanel deeplink={buildMetamaskDeeplink()} />
						) : !account ? (
							<button
								type="button"
								onClick={connectWallet}
								disabled={status === 'connecting'}
								className="w-full rounded-full bg-blue-600 px-8 py-4 text-lg font-bold text-white shadow-lg transition-all hover:bg-blue-500 active:scale-95 disabled:cursor-not-allowed disabled:opacity-60"
							>
								{status === 'connecting' ? 'Connecting…' : 'Connect wallet'}
							</button>
						) : !onBase ? (
							<button
								type="button"
								onClick={switchToBase}
								disabled={status === 'switching-chain'}
								className="w-full rounded-full bg-amber-500 px-8 py-4 text-lg font-bold text-white shadow-lg transition-all hover:bg-amber-400 active:scale-95 disabled:cursor-not-allowed disabled:opacity-60"
							>
								{status === 'switching-chain' ? 'Switching…' : 'Switch to Base'}
							</button>
						) : status === 'success' ? (
							<SuccessPanel usdcTx={result?.usdcTx} onDone={() => window.close()} />
						) : (
							<button
								type="button"
								onClick={payWithUsdc}
								disabled={
									status === 'awaiting-signature' ||
									status === 'settling' ||
									status === 'quoting' ||
									!quote
								}
								className="w-full rounded-full bg-blue-600 px-8 py-4 text-lg font-bold text-white shadow-lg transition-all hover:bg-blue-500 active:scale-95 disabled:cursor-not-allowed disabled:opacity-60"
							>
								{status === 'awaiting-signature' && 'Waiting for wallet signature…'}
								{status === 'settling' && 'Settling on-chain…'}
								{status === 'quoting' && 'Loading quote…'}
								{(status === 'idle' || status === 'error') && `Pay ${quotedUsdcLabel}`}
							</button>
						)}
						{ready && account ? (
							<p className="mt-3 text-center text-xs text-on-surface-variant">
								Connected as <span className="font-mono">{truncate(account, 6, 4)}</span>
							</p>
						) : null}
						{error ? (
							<div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800 dark:border-rose-800/50 dark:bg-rose-950/30 dark:text-rose-200">
								{error}
							</div>
						) : null}
					</section>
				</div>
			</main>
			<SiteFooter />
		</div>
	)
}

function Row({
	label,
	value,
	mono = false,
	bold = false,
	accent,
}: {
	label: string
	value: string
	mono?: boolean
	bold?: boolean
	accent?: 'rose'
}) {
	const accentCls = accent === 'rose' ? 'text-rose-600 dark:text-rose-400' : 'text-on-surface'
	return (
		<div className="flex items-center justify-between gap-4">
			<span className="text-on-surface-variant">{label}</span>
			<span className={`${mono ? 'font-mono' : ''} ${bold ? 'font-bold' : ''} ${accentCls}`}>{value}</span>
		</div>
	)
}

function Divider() {
	return <div className="my-1 h-px w-full bg-outline-variant/20" />
}

function NoWalletPanel({ deeplink }: { deeplink: string }) {
	return (
		<div className="rounded-2xl border border-amber-200 bg-amber-50 p-5 text-amber-900 dark:border-amber-700/50 dark:bg-amber-950/30 dark:text-amber-100">
			<p className="text-sm font-semibold">No browser wallet detected</p>
			<p className="mt-1 text-xs leading-relaxed opacity-90">
				Open this page inside your wallet's built-in browser (MetaMask, Rabby, Coinbase Wallet, etc.) to pay with
				USDC on Base.
			</p>
			<a
				href={deeplink}
				target="_blank"
				rel="noopener noreferrer"
				className="mt-4 inline-flex w-full items-center justify-center rounded-full bg-amber-600 px-6 py-3 text-sm font-bold text-white shadow-md transition-all hover:bg-amber-500 active:scale-95"
			>
				Open in MetaMask
			</a>
		</div>
	)
}

function SuccessPanel({ usdcTx, onDone }: { usdcTx?: string; onDone: () => void }) {
	return (
		<div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-6 text-emerald-900 dark:border-emerald-800/50 dark:bg-emerald-950/30 dark:text-emerald-100">
			<p className="text-lg font-bold">Payment confirmed</p>
			<p className="mt-1 text-sm opacity-90">USDC transferred to the merchant. You can close this page.</p>
			<div className="mt-4 grid gap-2 text-xs">
				{usdcTx ? (
					<a
						href={`https://basescan.org/tx/${usdcTx}`}
						target="_blank"
						rel="noopener noreferrer"
						className="font-mono underline hover:opacity-80"
					>
						USDC tx: {truncate(usdcTx, 10, 8)}
					</a>
				) : null}
			</div>
			<button
				type="button"
				onClick={onDone}
				className="mt-5 inline-flex w-full items-center justify-center rounded-full bg-emerald-600 px-6 py-3 text-sm font-bold text-white shadow-md transition-all hover:bg-emerald-500 active:scale-95"
			>
				Done
			</button>
		</div>
	)
}
