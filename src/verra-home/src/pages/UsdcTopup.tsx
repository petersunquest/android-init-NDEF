import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { createWalletClient, custom, type Address } from 'viem'
import { base } from 'viem/chains'
import { wrapFetchWithPayment, decodeXPaymentResponse } from 'x402-fetch'
import { MobileWalletPayPanel } from '../components/MobileWalletPayPanel'
import { SiteHeader } from '../components/SiteHeader'
import { isMobileDeviceForWalletApps } from '../utils/mobileWalletApps'

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
	amount?: string
	cardOwner?: string
}

type TopupParams = {
	cardAddress: string
	cardOwner: string
	/** 无 NFC 的 POS 两阶段 QR 可省略；有值时需与 e/c/m 成套 */
	uid: string
	e: string
	c: string
	m: string
	amount: string
	currency: string
	/** POS 轮询 `nfcUsdcChargeSession` 的 UUID v4；与 `pos` 成对出现在 POS 生成的 QR 上 */
	sid: string
	/** POS 终端 admin EOA（与 `sid` 成对）；后端据此走 POS 签 ExecuteForAdmin 闭环 */
	pos: string
}

const truncate = (s: string, head = 6, tail = 4): string =>
	s && s.length > head + tail + 3 ? `${s.slice(0, head)}…${s.slice(-tail)}` : s

const isHex = (s: string, len?: number): boolean =>
	typeof s === 'string' && /^[0-9a-fA-F]+$/.test(s) && (len === undefined || s.length === len)

const isEthAddress = (s: string): boolean => typeof s === 'string' && /^0x[0-9a-fA-F]{40}$/.test(s)

const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const isUuidV4 = (s: string): boolean => typeof s === 'string' && UUID_V4_RE.test(s)

function parseParams(sp: URLSearchParams): { ok: true; params: TopupParams } | { ok: false; error: string } {
	const cardAddress = (sp.get('card') ?? '').trim()
	const cardOwner = (sp.get('owner') ?? '').trim()
	const uid = (sp.get('uid') ?? '').trim()
	const e = (sp.get('e') ?? '').trim()
	const c = (sp.get('c') ?? '').trim()
	const m = (sp.get('m') ?? '').trim()
	const amount = (sp.get('amount') ?? '').trim()
	const currency = (sp.get('currency') ?? 'CAD').trim().toUpperCase()
	const sid = (sp.get('sid') ?? '').trim().toLowerCase()
	const pos = (sp.get('pos') ?? '').trim()
	if (!isEthAddress(cardAddress)) return { ok: false, error: 'Missing or invalid `card` (BeamioUserCard address)' }
	if (!isEthAddress(cardOwner)) return { ok: false, error: 'Missing or invalid `owner` (card owner EOA)' }
	if (sid && !isUuidV4(sid)) return { ok: false, error: 'Invalid `sid` (expect UUID v4)' }
	if (sid && !isEthAddress(pos)) return { ok: false, error: 'Missing or invalid `pos` when `sid` is set (POS terminal EOA)' }
	if (!sid && pos && !isEthAddress(pos)) return { ok: false, error: 'Invalid `pos` (expect checksummed EOA)' }
	const hasSidPos = Boolean(sid && isEthAddress(pos))
	if (!hasSidPos) {
		if (!uid || !isHex(uid, 14)) return { ok: false, error: 'Missing or invalid `uid` (NFC UID, 14 hex chars)' }
		if (!isHex(e, 64)) return { ok: false, error: 'Missing or invalid SUN `e` (64 hex chars)' }
		if (!isHex(c, 6)) return { ok: false, error: 'Missing or invalid SUN `c` (6 hex chars)' }
		if (!isHex(m, 16)) return { ok: false, error: 'Missing or invalid SUN `m` (16 hex chars)' }
	} else {
		if (uid) {
			if (!isHex(uid, 14)) return { ok: false, error: 'Invalid `uid` (expect 14 hex chars)' }
			if (!isHex(e, 64) || !isHex(c, 6) || !isHex(m, 16)) {
				return { ok: false, error: 'When `uid` is present, SUN params `e`, `c`, `m` are required' }
			}
		}
	}
	if (!amount || !(Number(amount) > 0)) return { ok: false, error: 'Missing or invalid `amount`' }
	if (!currency) return { ok: false, error: 'Missing `currency`' }
	return {
		ok: true,
		params: {
			cardAddress,
			cardOwner,
			uid: hasSidPos && !uid ? '' : uid,
			e: hasSidPos && !uid ? '' : e,
			c: hasSidPos && !uid ? '' : c,
			m: hasSidPos && !uid ? '' : m,
			amount,
			currency,
			sid,
			pos: pos && isEthAddress(pos) ? pos : '',
		},
	}
}

function formatCurrencyAmount(amount: string, currency: string): string {
	const n = Number(amount)
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

function isX402RequirementShapeError(errorMessage: string): boolean {
	return /maxAmountRequired|ZodError/i.test(errorMessage)
}

export function UsdcTopup() {
	const [sp] = useSearchParams()
	const parsed = useMemo(() => parseParams(sp), [sp])
	const [account, setAccount] = useState<Address | null>(null)
	const [chainIdHex, setChainIdHex] = useState<string | null>(null)
	const [quote, setQuote] = useState<QuoteResponse | null>(null)
	const [status, setStatus] = useState<Status>('idle')
	const [error, setError] = useState<string | null>(null)
	const [result, setResult] = useState<{
		usdcTx?: string
		topupTx?: string
		settle?: unknown
		/** POS QR：USDC 已结算，挂点mint 由终端 admin 离线签闭环 */
		awaitingPosAuthorization?: boolean
		/** POS 两阶段：仅 USDC 已付，顾客需在终端贴卡完成入账 */
		awaitingBeneficiaryTap?: boolean
	} | null>(null)

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
		const { cardAddress, cardOwner, amount, currency } = parsed.params
		setStatus((s) => (s === 'idle' ? 'quoting' : s))
		const url = `${BEAMIO_API}/api/nfcUsdcTopupQuote?card=${cardAddress}&owner=${cardOwner}&amount=${encodeURIComponent(amount)}&currency=${currency}`
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
	}, [parsed.ok ? parsed.params.cardAddress : '', parsed.ok ? parsed.params.cardOwner : '', parsed.ok ? parsed.params.amount : '', parsed.ok ? parsed.params.currency : ''])

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
			const err = e as { name?: string; message?: string; cause?: unknown; code?: number | string } | null
			const name = err?.name ?? typeof e
			const msg = err?.message ?? String(e)
			const codeStr = err?.code !== undefined ? ` code=${err.code}` : ''
			const causeStr = err?.cause ? ` cause=${err.cause instanceof Error ? err.cause.message : String(err.cause)}` : ''
			if (isX402RequirementShapeError(msg)) {
				setError(
					`Payment requirement schema mismatch from server (x402 maxAmountRequired). Please retry in a moment.${codeStr}${causeStr}`
				)
				setStatus('error')
				return
			}
			setError(`${name}: ${msg}${codeStr}${causeStr}`)
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
				// viem walletClient satisfies x402 SignerWallet shape
				walletClient as unknown as Parameters<typeof wrapFetchWithPayment>[1],
				BigInt(1_000_000_000) // 1000 USDC max guard, server enforces real price
			)
			const p = parsed.params
			const bodyObj: Record<string, string> = {
				cardAddress: p.cardAddress,
				cardOwner: p.cardOwner,
				amount: p.amount,
				currency: p.currency,
			}
			if (p.sid) bodyObj.sid = p.sid
			if (p.pos) bodyObj.pos = p.pos
			if (p.uid) {
				bodyObj.uid = p.uid
				bodyObj.e = p.e
				bodyObj.c = p.c
				bodyObj.m = p.m
			}
			const body = JSON.stringify(bodyObj)
			const response = await fetchWithPay(`${BEAMIO_API}/api/nfcUsdcTopup`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body,
			})
			setStatus('settling')
			const json = (await response.json().catch(() => ({}))) as {
				success?: boolean
				error?: string
				USDC_tx?: string
				executeForAdmin_tx?: string
				awaitingPosAuthorization?: boolean
				awaitingBeneficiaryTap?: boolean
			}
			const xPayResp = response.headers.get('x-payment-response')
			const decoded = xPayResp ? decodeXPaymentResponse(xPayResp) : null
			if (!response.ok || json.success === false) {
				setError(json.error ?? `Topup failed (HTTP ${response.status})`)
				setStatus('error')
				return
			}
			setResult({
				usdcTx: json.USDC_tx,
				topupTx: json.executeForAdmin_tx,
				settle: decoded,
				awaitingPosAuthorization: json.awaitingPosAuthorization === true,
				awaitingBeneficiaryTap: json.awaitingBeneficiaryTap === true,
			})
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
				<SiteHeader logoSrc="/beamio-logo.png" logoRounded wordmark="Beamio" />
				<main className="pt-24 pb-12">
					<div className="mx-auto max-w-xl px-6">
						<div className="rounded-2xl border border-rose-200 bg-rose-50 p-6 text-rose-800 dark:border-rose-800/50 dark:bg-rose-950/30 dark:text-rose-200">
							<h2 className="mb-2 text-xl font-bold">Invalid topup link</h2>
							<p className="text-sm leading-relaxed">{parsed.error}</p>
							<p className="mt-4 text-xs opacity-80">
								Expected: <code>card</code>, <code>owner</code>, <code>amount</code>, <code>currency</code>; with POS session{' '}
								<code>sid</code> + <code>pos</code> the NFC <code>uid</code>/<code>e</code>/<code>c</code>/<code>m</code> may be
								omitted (pay USDC first, then tap card on terminal). Without <code>sid</code>/<code>pos</code>, full NFC params are
								required.
							</p>
						</div>
					</div>
				</main>
			</div>
		)
	}

	const { cardAddress, cardOwner, uid, amount, currency, sid: topupSid } = parsed.params
	const showNfcTagRow = Boolean(uid && uid.length >= 6)
	const onBase = chainIdHex?.toLowerCase() === BASE_CHAIN_ID_HEX
	const hasWallet = !!eth
	const ready = hasWallet && !!account && onBase

	const quotedUsdcLabel = formatUsdc(quote?.quotedUsdc ?? quote?.quotedUsdc6)

	return (
		<div className="min-h-dvh bg-background text-on-surface antialiased">
			<SiteHeader logoSrc="/beamio-logo.png" logoRounded wordmark="Beamio" />
			<main className="pt-24 pb-12">
				<div className="mx-auto max-w-xl px-6">
					<header className="mb-8 text-center">
						<h1 className="text-3xl font-extrabold tracking-tight">Top up your card</h1>
						<p className="mt-2 text-on-surface-variant">
							Pay with USDC on Base from your own wallet.
							{topupSid
								? ' After payment, tap your Beamio card on the merchant terminal to receive the credit.'
								: ' Your NFC card will be credited automatically.'}
						</p>
					</header>

					<section className="rounded-3xl border border-outline-variant/20 bg-surface-container-lowest p-6 shadow-[0_4px_24px_rgba(0,0,0,0.04)]">
						<div className="grid grid-cols-1 gap-3 text-sm">
							<Row label="Top-up amount" value={formatCurrencyAmount(amount, currency)} mono={false} bold />
							<Row label="You pay" value={status === 'quoting' ? 'Quoting…' : quotedUsdcLabel} mono bold />
							<Divider />
							<Row label="Merchant (card owner)" value={truncate(cardOwner, 8, 6)} mono />
							<Row label="BeamioUserCard" value={truncate(cardAddress, 8, 6)} mono />
							{showNfcTagRow ? (
								<Row label="NFC tag" value={`…${uid.slice(-6).toUpperCase()}`} mono />
							) : (
								<Row label="NFC tag" value="After payment — tap card at terminal" mono={false} />
							)}
							<Row label="Network" value="Base mainnet" mono={false} />
						</div>
					</section>

					<section className="mt-6">
						{!hasWallet ? (
							isMobileDeviceForWalletApps() ? (
								<MobileWalletPayPanel fallbackDeeplink={buildMetamaskDeeplink()} />
							) : (
								<NoWalletPanel deeplink={buildMetamaskDeeplink()} />
							)
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
							<SuccessPanel
								usdcTx={result?.usdcTx}
								topupTx={result?.topupTx}
								awaitingPosAuthorization={result?.awaitingPosAuthorization}
								awaitingBeneficiaryTap={result?.awaitingBeneficiaryTap}
								onDone={() => window.close()}
							/>
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
		</div>
	)
}

function Row({
	label,
	value,
	mono = false,
	bold = false,
}: {
	label: string
	value: string
	mono?: boolean
	bold?: boolean
}) {
	return (
		<div className="flex items-center justify-between gap-4">
			<span className="text-on-surface-variant">{label}</span>
			<span className={`${mono ? 'font-mono' : ''} ${bold ? 'font-bold' : ''} text-on-surface`}>{value}</span>
		</div>
	)
}

function Divider() {
	return <div className="my-1 h-px w-full bg-outline-variant/20" />
}

/** Desktop / laptop only (mobile uses `MobileWalletPayPanel` instead). */
function NoWalletPanel({ deeplink }: { deeplink: string }) {
	return (
		<div className="rounded-2xl border border-amber-200 bg-amber-50 p-5 text-amber-900 dark:border-amber-700/50 dark:bg-amber-950/30 dark:text-amber-100">
			<p className="text-sm font-semibold">No browser wallet detected</p>
			<p className="mt-1 text-xs leading-relaxed opacity-90">
				Open this page inside your wallet's built-in browser (MetaMask, OKX Wallet, Base Wallet, etc.) to pay
				with USDC on Base.
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

function SuccessPanel({
	usdcTx,
	topupTx,
	awaitingPosAuthorization,
	awaitingBeneficiaryTap,
	onDone,
}: {
	usdcTx?: string
	topupTx?: string
	awaitingPosAuthorization?: boolean
	awaitingBeneficiaryTap?: boolean
	onDone: () => void
}) {
	return (
		<div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-6 text-emerald-900 dark:border-emerald-800/50 dark:bg-emerald-950/30 dark:text-emerald-100">
			<p className="text-lg font-bold">Payment confirmed</p>
			<p className="mt-1 text-sm opacity-90">
				{awaitingBeneficiaryTap
					? 'Your USDC payment is complete. Tap your Beamio card on the merchant terminal to finish top-up.'
					: awaitingPosAuthorization
						? 'Your USDC payment is complete. The merchant terminal will finalize crediting your card in a moment.'
						: 'USDC transferred and your NFC card will be topped up shortly.'}
			</p>
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
				{topupTx ? (
					<a
						href={`https://basescan.org/tx/${topupTx}`}
						target="_blank"
						rel="noopener noreferrer"
						className="font-mono underline hover:opacity-80"
					>
						NFC topup tx: {truncate(topupTx, 10, 8)}
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
