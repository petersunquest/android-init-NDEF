import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { createWalletClient, custom, getAddress, type Address } from 'viem'
import { base } from 'viem/chains'
import { MobileWalletPayPanel } from '../components/MobileWalletPayPanel'
import { SiteHeader } from '../components/SiteHeader'
import { WalletAppDappIconButtons } from '../components/WalletAppDappIconButtons'
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
const BASE_USDC_ADDRESS = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as Address

/** Cluster `GET /api/BeamioTransfer` success JSON (x402 settle via Master facilitator). */
type BeamioTransferOkResponse = {
	success?: boolean
	payer?: string
	USDC_tx?: string
	network?: string
	timestamp?: string
	error?: string
}

type PrecheckResponse = {
	success?: boolean
	error?: string
	payee?: string
	amount?: string
	currency?: string
	paymentUrl?: string
}

type PayFlowStatus = 'idle' | 'connecting' | 'switching-chain' | 'paying' | 'success' | 'error'

const truncate = (s: string, head = 6, tail = 4): string =>
	s && s.length > head + tail + 3 ? `${s.slice(0, head)}…${s.slice(-tail)}` : s

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

function formatUsdcPayLabel(amount: string): string {
	const n = Number(amount)
	if (!Number.isFinite(n) || n <= 0) return 'USDC'
	return `${n.toFixed(2)} USDC`
}

/**
 * x402 resource: `GET /api/BeamioTransfer` (see x402sdk `BeamioTransfer` in util.ts).
 * Required query: amount, toAddress, currency, currencyAmount (USDC P2P uses same human amount for both).
 */
function buildVouchersBeamioTransferUrl(recipient: Address, amountHuman: string): string {
	const q = new URLSearchParams({
		amount: amountHuman,
		toAddress: recipient,
		currency: 'USDC',
		currencyAmount: amountHuman,
		note: 'Vouchers',
		// Cluster：B-Unit 网络费由收款人承担（与 vouchersReceivePreCheck 一致），非付款人
		feePayerForBunit: 'payee',
	})
	return `${BEAMIO_API}/api/BeamioTransfer?${q.toString()}`
}

export function Vouchers() {
	const [sp] = useSearchParams()
	const [loading, setLoading] = useState(true)
	const [precheckError, setPrecheckError] = useState('')
	const [precheckOk, setPrecheckOk] = useState(false)

	const [account, setAccount] = useState<Address | null>(null)
	const [chainIdHex, setChainIdHex] = useState<string | null>(null)
	const [payFlowStatus, setPayFlowStatus] = useState<PayFlowStatus>('idle')
	const [payError, setPayError] = useState<string | null>(null)
	const [transferTx, setTransferTx] = useState<string | null>(null)

	const eth = typeof window !== 'undefined' ? window.ethereum : undefined

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
		return `ethereum:${BASE_USDC_ADDRESS}@8453/transfer?address=${to}&uint256=${atomic6}`
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
			setPrecheckError('')
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

	useEffect(() => {
		if (queryError || !eth) return
		;(async () => {
			try {
				const chain = (await eth.request({ method: 'eth_chainId' })) as string
				setChainIdHex(chain)
				const accounts = (await eth.request({ method: 'eth_accounts' })) as string[]
				if (accounts?.[0]) setAccount(getAddress(accounts[0] as Address))
			} catch {
				/* ignore */
			}
		})()
		const onAccounts = (accs: unknown) => {
			const list = accs as string[] | undefined
			setAccount(list?.[0] ? getAddress(list[0] as Address) : null)
		}
		const onChain = (chain: unknown) => setChainIdHex(typeof chain === 'string' ? chain : null)
		eth.on?.('accountsChanged', onAccounts as (...args: unknown[]) => void)
		eth.on?.('chainChanged', onChain as (...args: unknown[]) => void)
		return () => {
			eth.removeListener?.('accountsChanged', onAccounts as (...args: unknown[]) => void)
			eth.removeListener?.('chainChanged', onChain as (...args: unknown[]) => void)
		}
	}, [eth, queryError])

	const canSubmitPay = Boolean(eip681Url && !loading && precheckOk && atomic6 && isValidAddress)

	const hasWallet = !!eth
	const onBase = chainIdHex?.toLowerCase() === BASE_CHAIN_ID_HEX
	const ready = hasWallet && !!account && onBase

	const connectWallet = async () => {
		if (!eth) return
		setPayError(null)
		setPayFlowStatus('connecting')
		try {
			const accounts = (await eth.request({ method: 'eth_requestAccounts' })) as string[]
			setAccount(accounts[0] ? getAddress(accounts[0] as Address) : null)
			const chain = (await eth.request({ method: 'eth_chainId' })) as string
			setChainIdHex(chain)
			setPayFlowStatus('idle')
		} catch (e: unknown) {
			setPayError(e instanceof Error ? e.message : String(e))
			setPayFlowStatus('error')
		}
	}

	const switchToBase = async () => {
		if (!eth) return
		setPayError(null)
		setPayFlowStatus('switching-chain')
		try {
			await eth.request({
				method: 'wallet_switchEthereumChain',
				params: [{ chainId: BASE_CHAIN_ID_HEX }],
			})
			setChainIdHex(BASE_CHAIN_ID_HEX)
			setPayFlowStatus('idle')
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
					setPayFlowStatus('idle')
					return
				} catch (addErr: unknown) {
					setPayError(addErr instanceof Error ? addErr.message : String(addErr))
					setPayFlowStatus('error')
					return
				}
			}
			setPayError(err?.message ?? 'Failed to switch chain')
			setPayFlowStatus('error')
		}
	}

	const payUsdcTransfer = async () => {
		if (!eth || !account || !atomic6 || !isValidAddress) return
		setPayError(null)
		setPayFlowStatus('paying')
		setTransferTx(null)
		try {
			const walletClient = createWalletClient({
				account,
				chain: base,
				transport: custom(eth),
			})
			const recipient = getAddress(to)
			const transferUrl = buildVouchersBeamioTransferUrl(recipient, amount)
			const { wrapFetchWithPayment, decodeXPaymentResponse } = await import('x402-fetch')
			// Client ceiling must be >= server maxAmountRequired (atomic USDC6); +1 USDC buffer for rounding.
			const payMaxAtomic = BigInt(atomic6) + 1_000_000n
			const fetchWithPay = wrapFetchWithPayment(
				fetch,
				walletClient as unknown as Parameters<typeof wrapFetchWithPayment>[1],
				payMaxAtomic,
			)
			const response = await fetchWithPay(transferUrl, { method: 'GET' })
			const json = (await response.json().catch(() => ({}))) as BeamioTransferOkResponse
			const xPayResp = response.headers.get('x-payment-response')
			const decoded = xPayResp ? decodeXPaymentResponse(xPayResp) : null
			if (!response.ok || json.success === false) {
				const hint =
					response.status === 402
						? ' (x402 payment rejected or incomplete)'
						: response.status === 400 && json.error?.includes('B-Unit')
							? ' (recipient must have B-Unit balance for network fee)'
							: ''
				setPayError((json.error ?? `HTTP ${response.status}`) + hint)
				setPayFlowStatus('error')
				return
			}
			const txHash = json.USDC_tx?.trim()
			if (!txHash) {
				setPayError(
					decoded != null
						? 'Settled but no USDC_tx in body (check X-PAYMENT-RESPONSE)'
						: 'Missing USDC_tx in response',
				)
				setPayFlowStatus('error')
				return
			}
			setTransferTx(txHash)
			setPayFlowStatus('success')
		} catch (e: unknown) {
			const err = e as { name?: string; message?: string }
			const name = err?.name ?? typeof e
			const msg = err?.message ?? String(e)
			const hint =
				name === 'TypeError' && /Failed to fetch|NetworkError|Load failed/i.test(msg)
					? '\n[hint] Second x402 request may be blocked by CORS preflight: ensure OPTIONS for /api/BeamioTransfer allows X-PAYMENT and exposes X-PAYMENT-RESPONSE.'
					: ''
			setPayError(`${name}: ${msg}${hint}`)
			setPayFlowStatus('error')
		}
	}

	const payLabel = `Pay ${formatUsdcPayLabel(amount)}`

	if (queryError) {
		return (
			<div className="min-h-dvh bg-background text-on-surface antialiased">
				<SiteHeader logoSrc="/beamio-logo.png" logoRounded wordmark="Beamio" />
				<main className="pt-24 pb-12">
					<div className="mx-auto max-w-xl px-6">
						<div className="rounded-2xl border border-rose-200 bg-rose-50 p-6 text-rose-800 dark:border-rose-800/50 dark:bg-rose-950/30 dark:text-rose-200">
							<h2 className="mb-2 text-xl font-bold">Invalid payment link</h2>
							<p className="text-sm leading-relaxed">{queryError}</p>
							<p className="mt-4 text-xs opacity-80">
								Expected: <code>Amount</code>, <code>to</code> (recipient EOA), <code>currency=USDC</code>, and{' '}
								<code>acceptTokens</code> including <code>USDC</code>.
							</p>
						</div>
					</div>
				</main>
			</div>
		)
	}

	return (
		<div className="min-h-dvh bg-background text-on-surface antialiased">
			<SiteHeader logoSrc="/beamio-logo.png" logoRounded wordmark="Beamio" />
			<main className="pt-24 pb-12">
				<div className="mx-auto max-w-xl px-6">
					<header className="mb-8 text-center">
						<h1 className="text-3xl font-extrabold tracking-tight">Pay with USDC</h1>
						<p className="mt-2 text-on-surface-variant">
							Send USDC on Base via Beamio x402 (EIP-3009 authorization). Open in a wallet app, or connect a browser wallet and
							pay below.
						</p>
					</header>

					<section className="rounded-3xl border border-outline-variant/20 bg-surface-container-lowest p-6 shadow-[0_4px_24px_rgba(0,0,0,0.04)]">
						<div className="grid grid-cols-1 gap-3 text-sm">
							<Row label="Amount" value={`${amount} USDC`} mono={false} bold />
							<Row label="Recipient (EOA)" value={truncate(to, 8, 6)} mono />
							<Row label="Network" value="Base mainnet" mono={false} />
							<Divider />
							<Row
								label="Receiver precheck"
								value={loading ? 'Checking…' : precheckOk ? 'Passed' : precheckError ? 'Failed' : '—'}
								mono={false}
								bold
							/>
						</div>
						{!loading && precheckOk ? (
							<div className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900 dark:border-emerald-800/50 dark:bg-emerald-950/30 dark:text-emerald-100">
								<p className="font-semibold">Ready to pay</p>
								<p className="mt-1 opacity-90">Receiver precheck passed. Connect your wallet or open this page in a wallet app.</p>
							</div>
						) : null}
					</section>

					<section className="mt-6 space-y-3">
						{!hasWallet ? (
							isMobileDeviceForWalletApps() ? (
								<MobileWalletPayPanel
									title="Open in a wallet app"
									description="Choose a wallet to open this page in the app browser. Then connect and pay, or use Copy EIP-681 URL."
								/>
							) : (
								<NoWalletPanel />
							)
						) : !account ? (
							<button
								type="button"
								onClick={connectWallet}
								disabled={payFlowStatus === 'connecting'}
								className="w-full rounded-full bg-blue-600 px-8 py-4 text-lg font-bold text-white shadow-lg transition-all hover:bg-blue-500 active:scale-95 disabled:cursor-not-allowed disabled:opacity-60"
							>
								{payFlowStatus === 'connecting' ? 'Connecting…' : 'Connect wallet'}
							</button>
						) : !onBase ? (
							<button
								type="button"
								onClick={switchToBase}
								disabled={payFlowStatus === 'switching-chain'}
								className="w-full rounded-full bg-amber-500 px-8 py-4 text-lg font-bold text-white shadow-lg transition-all hover:bg-amber-400 active:scale-95 disabled:cursor-not-allowed disabled:opacity-60"
							>
								{payFlowStatus === 'switching-chain' ? 'Switching…' : 'Switch to Base'}
							</button>
						) : payFlowStatus === 'success' ? (
							<SuccessPanel usdcTx={transferTx ?? undefined} onDone={() => window.close()} />
						) : (
							<>
								<button
									type="button"
									onClick={payUsdcTransfer}
									disabled={!canSubmitPay || payFlowStatus === 'paying'}
									className="w-full rounded-full bg-blue-600 px-8 py-4 text-lg font-bold text-white shadow-lg transition-all hover:bg-blue-500 active:scale-95 disabled:cursor-not-allowed disabled:opacity-60"
								>
									{payFlowStatus === 'paying' ? 'Confirm in wallet…' : payLabel}
								</button>
								{canSubmitPay ? (
									<button
										type="button"
										onClick={() => void navigator.clipboard.writeText(eip681Url)}
										className="w-full rounded-full border-2 border-outline-variant/30 bg-transparent px-8 py-3 text-sm font-bold text-on-surface transition-all hover:bg-surface-container-high/50 active:scale-95"
									>
										Copy EIP-681 URL
									</button>
								) : null}
							</>
						)}
						{ready && account ? (
							<p className="mt-3 text-center text-xs text-on-surface-variant">
								Connected as <span className="font-mono">{truncate(account, 6, 4)}</span>
							</p>
						) : null}
						{!loading && precheckError ? (
							<div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800 dark:border-rose-800/50 dark:bg-rose-950/30 dark:text-rose-200">
								{precheckError}
							</div>
						) : null}
						{payError ? (
							<div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800 dark:border-rose-800/50 dark:bg-rose-950/30 dark:text-rose-200">
								{payError}
							</div>
						) : null}
						<p className="text-center text-xs text-on-surface-variant">
							Only send USDC on Base. Other tokens or networks may be lost. The recipient pays the B-Unit network fee (same as receiver precheck).
						</p>
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

function NoWalletPanel() {
	return (
		<div className="rounded-2xl border border-amber-200 bg-amber-50 p-5 text-amber-900 dark:border-amber-700/50 dark:bg-amber-950/30 dark:text-amber-100">
			<p className="text-sm font-semibold">No browser wallet detected</p>
			<p className="mt-1 text-xs leading-relaxed opacity-90">
				Open this page inside your wallet&apos;s built-in browser to connect and pay with USDC on Base. Tap an icon
				to open the app or store.
			</p>
			<WalletAppDappIconButtons className="mt-5" />
		</div>
	)
}

function SuccessPanel({ usdcTx, onDone }: { usdcTx?: string; onDone: () => void }) {
	return (
		<div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-6 text-emerald-900 dark:border-emerald-800/50 dark:bg-emerald-950/30 dark:text-emerald-100">
			<p className="text-lg font-bold">Payment sent</p>
			<p className="mt-1 text-sm opacity-90">USDC has been transferred to the merchant. You can close this page.</p>
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
