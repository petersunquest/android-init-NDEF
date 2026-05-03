import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { createWalletClient, custom, type Address } from 'viem'
import { base } from 'viem/chains'
import { wrapFetchWithPayment, decodeXPaymentResponse } from 'x402-fetch'
import { MobileWalletPayPanel } from '../components/MobileWalletPayPanel'
import { SiteFooter } from '../components/SiteFooter'
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
const BASE_CHAIN_ID = 8453
const BASE_USDC_ADDRESS = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as Address

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
	pos?: string | null
}

/**
 * 新 minimal schema（PR #1，iOS POS 唯一发出格式）:
 *   card + pos + subtotal + tipBps + taxBps + discountBps
 *   `cardOwner / currency` 由后端链上 `card.owner() / card.currency()` 解析后回填到 quote 响应。
 *   `discount / tax / tip` 绝对金额由后端 `subtotal × *Bps / 10000` 重算。
 *
 * 老 schema 向后兼容（NFC 模式 + 早期 no-NFC QR）:
 *   card + owner + subtotal + discount + tax + tip + *Bps + currency  (+ 可选 uid/e/c/m)
 *   收到 `owner` 字段 ⇒ 仍然校验/展示，但 quote 端会以链上 owner 为权威。
 *
 * NFC SUN: `uid + e + c + m` 任一存在但不完整 ⇒ 视为坏链接（防止 partial param 误传被 400）。
 */
type ChargeParams = {
	cardAddress: string
	pos: string
	cardOwner: string
	sid: string
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

const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const isUuidV4 = (s: string): boolean => typeof s === 'string' && UUID_V4_RE.test(s)

const numOrZero = (raw: string): number => {
	const n = Number((raw ?? '').toString().trim())
	return Number.isFinite(n) && n > 0 ? n : 0
}

/** 与 beamioServer `normalizeChargeBreakdown` 一致：显式金额优先，否则用 Bps 从小计/税后基数推算 */
function effectiveBreakdownTotals(p: {
	subtotal: string
	discount: string
	tax: string
	tip: string
	discountBps: string
	taxBps: string
	tipBps: string
}): { discount: number; tax: number; tip: number; total: number } {
	const sub = numOrZero(p.subtotal)
	const bps = (raw: string): number => {
		const n = Math.trunc(Number((raw ?? '').toString().trim()) || 0)
		if (!Number.isFinite(n) || n < 0) return 0
		return Math.min(10000, n)
	}
	const discBps = bps(p.discountBps)
	const taxB = bps(p.taxBps)
	const tipB = bps(p.tipBps)

	let discount = numOrZero(p.discount)
	if (discount <= 0 && discBps > 0) discount = (sub * discBps) / 10000
	const afterDisc = Math.max(0, sub - discount)

	let tax = numOrZero(p.tax)
	if (tax <= 0 && taxB > 0) tax = (afterDisc * taxB) / 10000

	let tip = numOrZero(p.tip)
	if (tip <= 0 && tipB > 0) tip = (sub * tipB) / 10000

	const total = Math.max(0, afterDisc + tax + tip)
	return { discount, tax, tip, total }
}

/** 合并 quote 与 URL（Bps 以 quote 为准若有），避免 API 返回 `tip: \"0.00\"` 但 `tipBps>0` 时误信绝对额 */
function mergedBreakdown(quote: QuoteResponse | null, p: ChargeParams) {
	const subtotalStr = String(quote?.subtotal ?? p.subtotal)
	return effectiveBreakdownTotals({
		subtotal: subtotalStr,
		discount: String(quote?.discount ?? p.discount),
		tax: String(quote?.tax ?? p.tax),
		tip: String(quote?.tip ?? p.tip),
		discountBps: String(quote?.discountBps ?? p.discountBps ?? '0'),
		taxBps: String(quote?.taxBps ?? p.taxBps ?? '0'),
		tipBps: String(quote?.tipBps ?? p.tipBps ?? '0'),
	})
}

/** 当 quote.total 未含 Bps 小费等项目而 canonical total 更大时，按比例放大 USDC6（Oracle 近似线性） */
function scaleUsdc6ToCanonicalTotal(
	atomic: string,
	apiTotal: number,
	canonicalTotal: number
): { scaled: string; didScale: boolean } {
	if (!/^\d+$/.test(atomic) || BigInt(atomic) <= 0n) return { scaled: atomic, didScale: false }
	if (!(apiTotal > 0) || !(canonicalTotal > 0)) return { scaled: atomic, didScale: false }
	const diff = Math.abs(apiTotal - canonicalTotal)
	if (diff < 0.005) return { scaled: atomic, didScale: false }
	const apiE6 = Math.max(1, Math.round(apiTotal * 1_000_000))
	const canE6 = Math.max(1, Math.round(canonicalTotal * 1_000_000))
	const scaled = (BigInt(atomic) * BigInt(canE6)) / BigInt(apiE6)
	if (scaled <= 0n) return { scaled: atomic, didScale: false }
	return { scaled: scaled.toString(), didScale: true }
}

function parseParams(sp: URLSearchParams): { ok: true; params: ChargeParams } | { ok: false; error: string } {
	const cardAddress = (sp.get('card') ?? '').trim()
	const pos = (sp.get('pos') ?? '').trim()
	const cardOwner = (sp.get('owner') ?? '').trim()
	const sid = (sp.get('sid') ?? '').trim().toLowerCase()
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
	const currency = (sp.get('currency') ?? '').trim().toUpperCase()
	if (!isEthAddress(cardAddress)) return { ok: false, error: 'Missing or invalid `card` (BeamioUserCard address)' }
	if (pos && !isEthAddress(pos)) return { ok: false, error: 'Invalid `pos` (POS terminal admin EOA)' }
	if (cardOwner && !isEthAddress(cardOwner)) return { ok: false, error: 'Invalid `owner` (card owner EOA)' }
	// `sid` 可选：POS 端会在 QR URL 里带 UUID v4 用于状态轮询；缺省/非法格式 ⇒ 当作普通 charge（向下兼容老 QR）
	if (sid && !isUuidV4(sid)) return { ok: false, error: 'Invalid `sid` (expect UUID v4)' }
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
	// Bps 三件套校验（0-10000，整数）
	const bpsCheck = (label: string, raw: string): string | null => {
		if (raw === '' || raw === '0') return null
		const n = Number(raw)
		if (!Number.isFinite(n) || n < 0 || n > 10000 || Math.trunc(n) !== n) {
			return `Invalid \`${label}\` (expect integer 0-10000)`
		}
		return null
	}
	for (const [label, raw] of [['discountBps', discountBps], ['taxBps', taxBps], ['tipBps', tipBps]] as const) {
		const err = bpsCheck(label, raw)
		if (err) return { ok: false, error: err }
	}
	// 老 schema 显式 amount；新 schema 只有 Bps 时与后端 normalizeChargeBreakdown 同口径推算 total（含 tipBps 等）
	const { total } = effectiveBreakdownTotals({
		subtotal,
		discount,
		tax,
		tip,
		discountBps,
		taxBps,
		tipBps,
	})
	if (!(total > 0)) return { ok: false, error: 'Invalid breakdown (total <= 0)' }
	return {
		ok: true,
		params: { cardAddress, pos, cardOwner, sid, uid, e, c, m, subtotal, discount, tax, tip, discountBps, taxBps, tipBps, currency },
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

function quoteToUsdc6Atomic(quote: QuoteResponse | null): string | null {
	const atomic = quote?.quotedUsdc6?.trim()
	if (atomic && /^\d+$/.test(atomic) && BigInt(atomic) > 0n) return atomic
	const human = quote?.quotedUsdc?.trim()
	if (!human) return null
	const n = Number(human)
	if (!Number.isFinite(n) || n <= 0) return null
	return BigInt(Math.round(n * 1_000_000)).toString()
}

/** 展示与 raw-sig 支付用：canonical breakdown + 在 API total 滞后时按比例修正 USDC6 */
function resolvePayPricing(quote: QuoteResponse | null, p: ChargeParams) {
	const b = mergedBreakdown(quote, p)
	const subtotalStr = String(quote?.subtotal ?? p.subtotal)
	const subtotalNum = Number(subtotalStr)
	const apiTotal =
		quote?.total != null && String(quote.total).trim() !== '' ? Number(quote.total) : b.total
	const baseAt = quoteToUsdc6Atomic(quote)
	let quotedUsdc6: string | null = baseAt
	let usdcScaledFromApi = false
	if (baseAt && apiTotal > 0) {
		const { scaled, didScale } = scaleUsdc6ToCanonicalTotal(baseAt, apiTotal, b.total)
		quotedUsdc6 = scaled
		usdcScaledFromApi = didScale
	}
	return {
		subtotalNum,
		discountNum: b.discount,
		taxNum: b.tax,
		tipNum: b.tip,
		totalNum: b.total,
		apiTotal,
		quotedUsdc6,
		usdcScaledFromApi,
	}
}

function randomBytes32Hex(): `0x${string}` {
	const bytes = new Uint8Array(32)
	crypto.getRandomValues(bytes)
	return `0x${Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')}`
}

function shouldFallbackToRawSignature(errorMessage: string): boolean {
	return /no valid assets?/i.test(errorMessage)
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
		// 仅送出 URL 中真正存在的字段；后端在缺省时会以 `card.owner() / card.currency()` 链上权威值兜底。
		const q = new URLSearchParams()
		q.set('card', p.cardAddress)
		q.set('subtotal', p.subtotal)
		if (p.pos) q.set('pos', p.pos)
		if (p.cardOwner) q.set('owner', p.cardOwner)
		if (p.currency) q.set('currency', p.currency)
		if (p.discount && Number(p.discount) > 0) q.set('discount', p.discount)
		if (p.tax && Number(p.tax) > 0) q.set('tax', p.tax)
		if (p.tip && Number(p.tip) > 0) q.set('tip', p.tip)
		if (p.discountBps && Number(p.discountBps) > 0) q.set('discountBps', p.discountBps)
		if (p.taxBps && Number(p.taxBps) > 0) q.set('taxBps', p.taxBps)
		if (p.tipBps && Number(p.tipBps) > 0) q.set('tipBps', p.tipBps)
		const url = `${BEAMIO_API}/api/nfcUsdcChargeQuote?${q.toString()}`
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
		parsed.ok ? parsed.params.pos : '',
		parsed.ok ? parsed.params.cardOwner : '',
		parsed.ok ? parsed.params.subtotal : '',
		parsed.ok ? parsed.params.discount : '',
		parsed.ok ? parsed.params.tax : '',
		parsed.ok ? parsed.params.tip : '',
		parsed.ok ? parsed.params.discountBps : '',
		parsed.ok ? parsed.params.taxBps : '',
		parsed.ok ? parsed.params.tipBps : '',
		parsed.ok ? parsed.params.currency : '',
	])

	const pricing = useMemo(() => {
		if (!parsed.ok) return null
		return resolvePayPricing(quote, parsed.params)
	}, [parsed, quote])

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
		const walletClient = createWalletClient({
			account,
			chain: base,
			transport: custom(eth),
		})
		const submitRawSignatureFallback = async (): Promise<void> => {
			if (!parsed.ok) throw new Error('Invalid charge link')
			const pay = resolvePayPricing(quote, parsed.params)
			const value = pay.quotedUsdc6 ?? quoteToUsdc6Atomic(quote)
			if (!value) throw new Error('Missing USDC quote for raw signature fallback')
			const now = Math.floor(Date.now() / 1000)
			const validAfter = Math.max(0, now - 600).toString()
			const validBefore = (now + 120).toString()
			const nonce = randomBytes32Hex()
			const payTo = (quote?.cardOwner ?? parsed.params.cardOwner ?? '').trim()
			if (!isEthAddress(payTo)) throw new Error('Cannot resolve merchant card owner for raw signature fallback')
			const signature = await walletClient.signTypedData({
				account,
				domain: {
					name: 'USD Coin',
					version: '2',
					chainId: BASE_CHAIN_ID,
					verifyingContract: BASE_USDC_ADDRESS,
				},
				types: {
					TransferWithAuthorization: [
						{ name: 'from', type: 'address' },
						{ name: 'to', type: 'address' },
						{ name: 'value', type: 'uint256' },
						{ name: 'validAfter', type: 'uint256' },
						{ name: 'validBefore', type: 'uint256' },
						{ name: 'nonce', type: 'bytes32' },
					],
				},
				primaryType: 'TransferWithAuthorization',
				message: {
					from: account,
					to: payTo as Address,
					value: BigInt(value),
					validAfter: BigInt(validAfter),
					validBefore: BigInt(validBefore),
					nonce,
				},
			})
			setStatus('settling')
			const p = parsed.params
			const bodyObj: Record<string, string> = {
				card: p.cardAddress,
				subtotal: p.subtotal,
				payer: account,
				value,
				validAfter,
				validBefore,
				nonce,
				signature,
			}
			if (p.pos) bodyObj.pos = p.pos
			if (p.currency) bodyObj.currency = p.currency
			if (p.discount && Number(p.discount) > 0) bodyObj.discount = p.discount
			if (p.tax && Number(p.tax) > 0) bodyObj.tax = p.tax
			if (p.tip && Number(p.tip) > 0) bodyObj.tip = p.tip
			if (p.discountBps && Number(p.discountBps) > 0) bodyObj.discountBps = p.discountBps
			if (p.taxBps && Number(p.taxBps) > 0) bodyObj.taxBps = p.taxBps
			if (p.tipBps && Number(p.tipBps) > 0) bodyObj.tipBps = p.tipBps
			if (p.sid) bodyObj.sid = p.sid
			const response = await fetch(`${BEAMIO_API}/api/nfcUsdcChargeRawSig`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(bodyObj),
			})
			const json = (await response.json().catch(() => ({}))) as {
				success?: boolean
				error?: string
				USDC_tx?: string
			}
			if (!response.ok || json.success === false) {
				throw new Error(json.error ?? `Raw signature charge failed (HTTP ${response.status})`)
			}
			setResult({ usdcTx: json.USDC_tx })
			setStatus('success')
		}
		try {
			const fetchWithPay = wrapFetchWithPayment(
				fetch,
				walletClient as unknown as Parameters<typeof wrapFetchWithPayment>[1],
				BigInt(1_000_000_000)
			)
			// 新 minimal schema body：只包含 URL 实际带的字段，让后端自己用链上 owner/currency 兜底。
			// 同时保留 cardAddress/cardOwner 别名以让老 cluster 也能解析（向下兼容期）。
			const p = parsed.params
			const bodyObj: Record<string, string> = {
				card: p.cardAddress,
				cardAddress: p.cardAddress,
				subtotal: p.subtotal,
			}
			if (p.pos) bodyObj.pos = p.pos
			if (p.cardOwner) {
				bodyObj.owner = p.cardOwner
				bodyObj.cardOwner = p.cardOwner
			}
			if (p.currency) bodyObj.currency = p.currency
			if (p.discount && Number(p.discount) > 0) bodyObj.discount = p.discount
			if (p.tax && Number(p.tax) > 0) bodyObj.tax = p.tax
			if (p.tip && Number(p.tip) > 0) bodyObj.tip = p.tip
			if (p.discountBps && Number(p.discountBps) > 0) bodyObj.discountBps = p.discountBps
			if (p.taxBps && Number(p.taxBps) > 0) bodyObj.taxBps = p.taxBps
			if (p.tipBps && Number(p.tipBps) > 0) bodyObj.tipBps = p.tipBps
			if (p.uid) bodyObj.uid = p.uid
			if (p.e) bodyObj.e = p.e
			if (p.c) bodyObj.c = p.c
			if (p.m) bodyObj.m = p.m
			if (p.sid) bodyObj.sid = p.sid
			const body = JSON.stringify(bodyObj)
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
			// x402 第二跳（带 X-PAYMENT）若被 CORS 预检 block，浏览器会抛 `TypeError: Failed to fetch`，
			// 这里把 name / message / cause / stack 全部 dump 到 console 并显示在 UI，方便区分：
			//   * TypeError + "Failed to fetch"        → CORS 预检失败（多半 nginx 没放行 X-PAYMENT），或 net::ERR_*
			//   * Error  + "User rejected the request" → 钱包用户拒签
			//   * 其他                                  → 看 cause / stack
			const err = e as { name?: string; message?: string; cause?: unknown; code?: number | string; stack?: string } | null
			const name = err?.name ?? typeof e
			const msg = err?.message ?? String(e)
			const causeStr = err?.cause ? ` cause=${err.cause instanceof Error ? err.cause.message : String(err.cause)}` : ''
			const codeStr = err?.code !== undefined ? ` code=${err.code}` : ''
			const hint = (name === 'TypeError' && /Failed to fetch|NetworkError|Load failed/i.test(msg))
				? '\n[hint] 浏览器在第二跳 fetch 阶段就失败了，最常见是 CORS 预检 block：请检查 https://beamio.app/api/nfcUsdcCharge 对 OPTIONS 是否在 Access-Control-Allow-Headers 中包含 X-PAYMENT，并在 Access-Control-Expose-Headers 中包含 X-PAYMENT-RESPONSE。'
				: ''
			console.error('[UsdcCharge] payWithUsdc failed', { name, msg, code: err?.code, cause: err?.cause, stack: err?.stack })
			if (shouldFallbackToRawSignature(msg)) {
				try {
					await submitRawSignatureFallback()
					return
				} catch (fallbackError: unknown) {
					const fbMsg = fallbackError instanceof Error ? fallbackError.message : String(fallbackError)
					console.error('[UsdcCharge] raw signature fallback failed', fallbackError)
					setError(`${name}: ${msg}\nRaw signature fallback failed: ${fbMsg}`)
					setStatus('error')
					return
				}
			}
			setError(`${name}: ${msg}${codeStr}${causeStr}${hint}`)
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
								Required: <code>card</code> (BeamioUserCard), <code>subtotal</code>. Recommended:{' '}
								<code>pos</code> (POS terminal admin EOA). Optional Bps: <code>tipBps</code>,{' '}
								<code>taxBps</code>, <code>discountBps</code> (integer 0-10000). The card owner address
								and currency are read on-chain — no need to put them in the URL. NFC SUN (
								<code>uid</code>+<code>e</code>+<code>c</code>+<code>m</code>) is optional — provide all
								four for NFC-bound charges, or none for pure third-party-wallet payment.
							</p>
						</div>
					</div>
				</main>
				<SiteFooter />
			</div>
		)
	}

	const { cardAddress, uid } = parsed.params
	const hasNfcSun = uid.length > 0
	const onBase = chainIdHex?.toLowerCase() === BASE_CHAIN_ID_HEX
	const hasWallet = !!eth
	const ready = hasWallet && !!account && onBase

	// 优先用 quote 里的链上权威 owner/currency；金额行与 USDC 用 mergedBreakdown + API 纠偏（线上 API 可能尚未含 Bps 小费）
	const cardOwner = (quote?.cardOwner ?? parsed.params.cardOwner ?? '').trim()
	const currency = (quote?.currency ?? parsed.params.currency ?? '').trim().toUpperCase() || 'CAD'
	const subtotalNum = pricing?.subtotalNum ?? 0
	const discountNum = pricing?.discountNum ?? 0
	const taxNum = pricing?.taxNum ?? 0
	const tipNum = pricing?.tipNum ?? 0
	const totalNum = pricing?.totalNum ?? 0
	const quotedUsdcLabel = formatUsdc(pricing?.quotedUsdc6 ?? undefined)

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
							{pricing?.usdcScaledFromApi ? (
								<p className="col-span-full text-xs text-amber-700 dark:text-amber-300">
									The quote API total did not include Bps-based items (e.g. tip); the USDC amount shown is scaled to
									match this bill. Deploy the latest API for exact quotes. Standard x402 payment may still use the
									server-settled amount until then.
								</p>
							) : null}
							<Divider />
							<Row
								label="Merchant (card owner)"
								value={cardOwner ? truncate(cardOwner, 8, 6) : 'Resolving on-chain…'}
								mono
							/>
							<Row label="BeamioUserCard" value={truncate(cardAddress, 8, 6)} mono />
							{hasNfcSun ? (
								<Row label="NFC tag" value={`…${uid.slice(-6).toUpperCase()}`} mono />
							) : null}
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
