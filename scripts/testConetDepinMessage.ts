#!/usr/bin/env npx tsx
/**
 * CoNET DePIN chat / gossip message diagnostic harness (Tor-like privacy model).
 *
 * Client privacy (must match SilentPassUI / bizSite product intent):
 *   - SEND: encrypt to **recipient user PGP**, HTTP POST `/post` only to random **entry A**
 *     (never to mailbox B domain / IP — that would reveal sender IP to B).
 *   - LISTEN: encrypt `mining` command to **route B public key**, but HTTP/SSE `/post` only to
 *     random **entry C ≠ B**. C `socketForward`s to B:80; B sees C’s IP, not the client’s.
 *   - Node↔node (A→B, C→B): **HTTP :80 only** (SI `socketForward`).
 *
 * Message shape (SilentPassUI `sendMessage` / `connectToGossipNode`):
 *   - Outer envelope: `{ timestamp, text, from, signMessage }` where `signMessage` is EIP-191 of `text`
 *   - Ciphertext: OpenPGP encrypt `base64(JSON.stringify(envelope))` to recipient user pubkey
 *   - Listen: encrypt `{ message, signMessage }` (mining) to **B** pubkey; POST body `{ data }` via **C**
 *
 * Usage:
 *   npx tsx scripts/testConetDepinMessage.ts probe --to 0x11C7…
 *   npx tsx scripts/testConetDepinMessage.ts send --to 0x11C7… --from-pk 0x…
 *   npx tsx scripts/testConetDepinMessage.ts roundtrip --to-pk 0x… --from-pk 0x…
 *
 * Env:
 *   CONET_RPC, ADDRESS_PGP, GUARDIAN_NODES
 *   ENTRY_COUNT (default 4), LISTEN_MS (default 45000)
 *   TEST_TEXT — custom plaintext for send/roundtrip (`text` field signed + encrypted)
 *   SCHEME=https|http|both (default **both**: https then http; SilentPassUI browsers use https)
 *   INSECURE_TLS=1 — only when isolating https leaf issues
 *   RECIPIENT_PGP_PRIVATE_ARMORED / TO_PGP_PRIVATE — roundtrip decrypt
 *
 * Security: never logs private keys, full armored ciphertext, or long decrypted secrets.
 */

import { createRequire } from 'node:module'
import * as fs from 'node:fs'
import * as path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { ethers } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.join(__dirname, '..')

const RPC = process.env.CONET_RPC || 'https://rpc1.conet.network'
const ADDRESS_PGP =
	process.env.ADDRESS_PGP ||
	readJsonAddress('deployments/conet-AddressPGP.json', 'AddressPGP') ||
	'0x684b0ac760cEE9c9b85de36d69746420648Cf9e2'
const GUARDIAN_NODES =
	process.env.GUARDIAN_NODES ||
	readJsonAddress('deployments/conet-AddressPGP.json', 'guardianNodesInfoV6') ||
	'0xBC6b53065b5647261396d002bDBA0d3396E0722f'

const ENTRY_COUNT = Math.max(1, Number(process.env.ENTRY_COUNT || 4))
const LISTEN_MS = Math.max(5_000, Number(process.env.LISTEN_MS || 45_000))
/**
 * SilentPassUI browsers POST https://{domain}.conet.network/post.
 * CLI default **both** (https then http) so incomplete entry leaf certs do not false-fail the model.
 */
const SCHEME_MODE = (process.env.SCHEME || 'both').toLowerCase() as 'http' | 'https' | 'both'

type EntryScheme = 'http' | 'https'

function entrySchemes(): EntryScheme[] {
	if (SCHEME_MODE === 'http') return ['http']
	if (SCHEME_MODE === 'https') return ['https']
	// Prefer https first (SilentPassUI); http fallback for CLI / incomplete entry leaf chains.
	return ['https', 'http']
}

function entryUrl(scheme: EntryScheme, domain: string, pathSuffix: string): string {
	return `${scheme}://${domain.toLowerCase()}.conet.network${pathSuffix}`
}

const FALLBACK_DOMAINS = [
	'9977E9A45187DD80',
	'B4CB0A41352E9BDF',
	'20AB90FE82D0E9E3',
	'AE85A2AEEC768225',
	'F8117E1568EEAED7',
] as const

type StepResult = {
	step: string
	ok: boolean
	detail: Record<string, unknown>
}

type SearchKeyRow = {
	userPgpKeyID: string
	userPublicKeyArmoredB64: string
	routeKeyID: string
	routePublicKeyArmoredB64: string
	routeOnline: boolean
}

type OpenPgpMod = typeof import('openpgp')

function readJsonAddress(rel: string, key: string): string | null {
	try {
		const p = path.join(ROOT, rel)
		if (!fs.existsSync(p)) return null
		const j = JSON.parse(fs.readFileSync(p, 'utf8')) as Record<string, string>
		return j[key] || null
	} catch {
		return null
	}
}

function parseArgs(argv: string[]) {
	const mode = (argv[2] || 'probe').toLowerCase()
	const out: {
		mode: string
		to?: string
		toPk?: string
		fromPk?: string
		entry?: string
		text?: string
	} = { mode }
	for (let i = 3; i < argv.length; i++) {
		const a = argv[i]
		const n = argv[i + 1]
		if (a === '--to' && n) {
			out.to = n
			i++
		} else if (a === '--to-pk' && n) {
			out.toPk = n
			i++
		} else if ((a === '--from-pk' || a === '--sender-pk') && n) {
			out.fromPk = n
			i++
		} else if (a === '--entry' && n) {
			out.entry = n
			i++
		} else if (a === '--text' && n) {
			out.text = n
			i++
		}
	}
	if (process.env.TEST_TEXT && !out.text) out.text = process.env.TEST_TEXT
	return out
}

function normalizePk(raw: string | undefined): string | null {
	if (!raw) return null
	const h = raw.trim().replace(/^0x/i, '')
	if (!/^[0-9a-fA-F]{64}$/.test(h)) return null
	return `0x${h}`
}

function normDomain(raw: unknown): string | null {
	const d = String(raw ?? '')
		.trim()
		.toUpperCase()
	return /^[0-9A-F]{16}$/.test(d) ? d : null
}

function shuffleTake<T>(arr: T[], n: number): T[] {
	const a = [...arr]
	for (let i = a.length - 1; i > 0; i--) {
		const j = Math.floor(Math.random() * (i + 1))
		;[a[i], a[j]] = [a[j]!, a[i]!]
	}
	return a.slice(0, Math.min(n, a.length))
}

/**
 * Client-facing entry pool: **never** include mailbox B.
 * Direct client→B would reveal the client IP to the mailbox (breaks Tor-like privacy).
 */
function pickClientEntryDomains(params: {
	allDomains: string[]
	mailboxB: string | null
	count: number
	preferred?: string | null
}): string[] {
	const exclude = new Set<string>()
	if (params.mailboxB) exclude.add(params.mailboxB)
	const pool = params.allDomains.filter((d) => !exclude.has(d))
	const source = pool.length ? pool : params.allDomains
	const pinned: string[] = []
	const push = (d: string | null | undefined) => {
		const n = d ? normDomain(d) : null
		if (!n || exclude.has(n) || pinned.includes(n)) return
		if (source.includes(n) || FALLBACK_DOMAINS.includes(n as (typeof FALLBACK_DOMAINS)[number])) {
			pinned.push(n)
		}
	}
	push(params.preferred)
	for (const d of FALLBACK_DOMAINS) push(d)
	const rest = shuffleTake(
		source.filter((d) => !pinned.includes(d)),
		Math.max(0, params.count - pinned.length),
	)
	return [...pinned, ...rest].slice(0, Math.max(params.count, 4))
}

function b64DecodeUtf8(b64: string): string | null {
	try {
		return Buffer.from(b64, 'base64').toString('utf8')
	} catch {
		return null
	}
}

function printStep(r: StepResult) {
	const mark = r.ok ? 'PASS' : 'FAIL'
	console.log(`\n[${mark}] ${r.step}`)
	for (const [k, v] of Object.entries(r.detail)) {
		const s = typeof v === 'string' ? v : JSON.stringify(v)
		console.log(`  ${k}: ${s}`)
	}
}

async function loadOpenPgp(): Promise<OpenPgpMod> {
	try {
		return (await import('openpgp')) as OpenPgpMod
	} catch {
		/* fall through */
	}
	const candidates = [
		path.join(ROOT, 'src/bizSite/node_modules/openpgp/dist/node/openpgp.mjs'),
		path.join(ROOT, 'src/posPwa/node_modules/openpgp/dist/node/openpgp.mjs'),
		path.join(ROOT, 'src/SilentPassUI/node_modules/openpgp/dist/node/openpgp.mjs'),
	]
	for (const p of candidates) {
		if (!fs.existsSync(p)) continue
		return (await import(pathToFileURL(p).href)) as OpenPgpMod
	}
	const req = createRequire(path.join(ROOT, 'src/bizSite/package.json'))
	try {
		return req('openpgp') as OpenPgpMod
	} catch {
		throw new Error(
			'openpgp not found. Run from repo with src/bizSite deps installed, or: cd src/bizSite && npm i',
		)
	}
}

async function searchKey(provider: ethers.Provider, wallet: string): Promise<SearchKeyRow> {
	const pgp = new ethers.Contract(
		ADDRESS_PGP,
		['function searchKey(address) view returns (string,string,string,string,bool)'],
		provider,
	)
	const sk = (await pgp.searchKey(ethers.getAddress(wallet))) as [
		string,
		string,
		string,
		string,
		boolean,
	]
	return {
		userPgpKeyID: String(sk[0] ?? ''),
		userPublicKeyArmoredB64: String(sk[1] ?? ''),
		routeKeyID: String(sk[2] ?? '').toUpperCase(),
		routePublicKeyArmoredB64: String(sk[3] ?? ''),
		routeOnline: Boolean(sk[4]),
	}
}

async function fetchGuardianDomains(provider: ethers.Provider): Promise<string[]> {
	const abi = [
		'function getAllNodes(uint256 start,uint256 length) view returns (tuple(uint256 id,string PGP,string PGPKey,string ip_addr,string regionName)[])',
	]
	const c = new ethers.Contract(GUARDIAN_NODES, abi, provider)
	try {
		const pages = await Promise.all([
			c.getAllNodes(0, 400) as Promise<unknown[]>,
			c.getAllNodes(400, 400) as Promise<unknown[]>,
		])
		const domains = Array.from(
			new Set(
				pages
					.flat()
					.map((node) =>
						normDomain(
							(node as { PGPKey?: unknown })?.PGPKey ?? (node as readonly unknown[])?.[2],
						),
					)
					.filter((d): d is string => Boolean(d)),
			),
		)
		if (domains.length) return domains
	} catch (e) {
		console.warn(
			'[warn] getAllNodes failed, using fallback domains:',
			e instanceof Error ? e.message : String(e),
		)
	}
	return [...FALLBACK_DOMAINS]
}

async function entryGetHealth(
	scheme: EntryScheme,
	domain: string,
	timeoutMs = 5_000,
): Promise<{
	scheme: EntryScheme
	domain: string
	ok: boolean
	status?: number
	error?: string
	tlsHint?: string
	ms: number
	url: string
}> {
	const url = entryUrl(scheme, domain, '/')
	const t0 = Date.now()
	try {
		const res = await fetch(url, {
			method: 'GET',
			headers: { Accept: 'text/html' },
			signal: AbortSignal.timeout(timeoutMs),
			cache: 'no-store',
		})
		return {
			scheme,
			domain,
			ok: res.status > 0 && res.status < 500,
			status: res.status,
			ms: Date.now() - t0,
			url,
		}
	} catch (e) {
		const cause = (e as { cause?: { code?: string; message?: string } })?.cause
		const code = cause?.code || (e instanceof Error ? e.message : String(e))
		const tlsHint =
			scheme === 'https' &&
			(code === 'UNABLE_TO_VERIFY_LEAF_SIGNATURE' || String(code).includes('certificate'))
				? 'HTTPS leaf/chain issue on entry. Retry SCHEME=http or INSECURE_TLS=1. Node↔node is still HTTP:80.'
				: undefined
		return {
			scheme,
			domain,
			ok: false,
			error: String(code),
			tlsHint,
			ms: Date.now() - t0,
			url,
		}
	}
}

async function entryPost(
	scheme: EntryScheme,
	domain: string,
	armored: string,
	timeoutMs = 12_000,
): Promise<{
	scheme: EntryScheme
	domain: string
	ok: boolean
	status?: number
	error?: string
	tlsHint?: string
	ms: number
	contentType?: string | null
	url: string
}> {
	const url = entryUrl(scheme, domain, '/post')
	const t0 = Date.now()
	try {
		const res = await fetch(url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ data: armored }),
			signal: AbortSignal.timeout(timeoutMs),
		})
		return {
			scheme,
			domain,
			ok: res.ok,
			status: res.status,
			ms: Date.now() - t0,
			contentType: res.headers.get('content-type'),
			url,
		}
	} catch (e) {
		const cause = (e as { cause?: { code?: string } })?.cause
		const code = cause?.code || (e instanceof Error ? e.message : String(e))
		const tlsHint =
			scheme === 'https' &&
			(code === 'UNABLE_TO_VERIFY_LEAF_SIGNATURE' || String(code).includes('certificate'))
				? 'HTTPS cert failure — try SCHEME=http. Unrelated to A→B HTTP:80 forward.'
				: undefined
		return {
			scheme,
			domain,
			ok: false,
			error: String(code),
			tlsHint,
			ms: Date.now() - t0,
			url,
		}
	}
}

/** Prefer schemes in order; return first 2xx. */
async function entryPostAnyScheme(
	domain: string,
	armored: string,
): Promise<Awaited<ReturnType<typeof entryPost>>> {
	let last: Awaited<ReturnType<typeof entryPost>> | null = null
	for (const scheme of entrySchemes()) {
		last = await entryPost(scheme, domain, armored)
		if (last.ok) return last
	}
	return last!
}

/**
 * SilentPassUI `sendMessage` envelope:
 *   sign EIP-191(`text`) → `{ timestamp, text, from, signMessage }` → base64 → encrypt to user PGP.
 */
async function encryptSilentPassSendEnvelope(params: {
	openpgp: OpenPgpMod
	recipientArmoredPub: string
	fromPk: string
	text: string
}): Promise<{ armored: string; from: string; sendId: string }> {
	const { createMessage, encrypt, enums, readKey } = params.openpgp
	const wallet = new ethers.Wallet(params.fromPk)
	const sendId = ethers.id(`conet-depin-test-${Date.now()}`).slice(0, 18)
	const text = params.text.includes('sendId')
		? params.text
		: JSON.stringify({
				type: 'conet_depin_message_test_v1',
				sendId,
				createdAt: Date.now(),
				note: params.text,
			})
	const signMessage = await wallet.signMessage(text)
	const envelope = {
		timestamp: Date.now(),
		text,
		from: wallet.address.toLowerCase(),
		signMessage,
	}
	const literal = Buffer.from(JSON.stringify(envelope), 'utf8').toString('base64')
	const armored = await encrypt({
		message: await createMessage({ text: literal }),
		encryptionKeys: await readKey({ armoredKey: params.recipientArmoredPub }),
		config: { preferredCompressionAlgorithm: enums.compression.zlib },
	})
	const out = typeof armored === 'string' ? armored : String((armored as { data?: string })?.data ?? armored)
	return { armored: out, from: wallet.address, sendId }
}

/** SilentPassUI `connectToGossipNode` mining listen — encrypt to **B**, HTTP via **C**. */
async function encryptMiningListenCommand(params: {
	openpgp: OpenPgpMod
	routeArmoredPub: string
	walletPk: string
}): Promise<string> {
	const { createMessage, encrypt, enums, readKey } = params.openpgp
	const wallet = new ethers.Wallet(params.walletPk)
	const securityKey = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('base64')
	const command = {
		command: 'mining',
		walletAddress: wallet.address,
		algorithm: 'aes-256-cbc',
		Securitykey: securityKey,
	}
	const message = JSON.stringify(command)
	const signMessage = await wallet.signMessage(message)
	const literal = Buffer.from(JSON.stringify({ message, signMessage }), 'utf8').toString('base64')
	const armored = await encrypt({
		message: await createMessage({ text: literal }),
		encryptionKeys: await readKey({ armoredKey: params.routeArmoredPub }),
		config: { preferredCompressionAlgorithm: enums.compression.zlib },
	})
	return typeof armored === 'string' ? armored : String((armored as { data?: string })?.data ?? armored)
}

async function listenForMessage(params: {
	openpgp: OpenPgpMod
	entryDomain: string
	listenArmored: string
	recipientPgpPrivateArmored: string
	expectSendId?: string
	timeoutMs: number
}): Promise<{ ok: boolean; preview?: string; error?: string; url?: string }> {
	const { decrypt, readMessage, readPrivateKey, decryptKey } = params.openpgp
	let pk = await readPrivateKey({ armoredKey: params.recipientPgpPrivateArmored })
	if (!pk.isDecrypted()) {
		pk = await decryptKey({ privateKey: pk, passphrase: '' })
	}

	const schemes = entrySchemes()
	const errors: string[] = []

	for (const scheme of schemes) {
		const url = entryUrl(scheme, params.entryDomain, '/post')
		const ctrl = new AbortController()
		const timer = setTimeout(() => ctrl.abort(), params.timeoutMs)
		try {
			const res = await fetch(url, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Accept: 'text/event-stream',
				},
				body: JSON.stringify({ data: params.listenArmored }),
				signal: ctrl.signal,
			})
			if (!res.ok || !res.body) {
				errors.push(`${scheme} HTTP ${res.status}`)
				clearTimeout(timer)
				continue
			}

			const reader = res.body.getReader()
			const decoder = new TextDecoder()
			let buf = ''
			const deadline = Date.now() + params.timeoutMs

			while (Date.now() < deadline) {
				const { value, done } = await reader.read()
				if (done) break
				buf += decoder.decode(value, { stream: true })
				const parts = buf.split('\n')
				buf = parts.pop() ?? ''
				for (const line of parts) {
					const trimmed = line.trim()
					if (!trimmed.startsWith('data:')) continue
					const payload = trimmed.slice(5).trim()
					if (!payload || payload === '[DONE]') continue
					try {
						const data = JSON.parse(payload) as { data?: string; from?: string; text?: string }
						if (data?.data && /^-----BEGIN PGP MESSAGE-----/i.test(data.data)) {
							try {
								const msg = await readMessage({ armoredMessage: data.data })
								const { data: decrypted } = await decrypt({
									message: msg,
									decryptionKeys: pk,
								})
								const decryptedString =
									typeof decrypted === 'string' ? decrypted : String(decrypted)
								let plain = decryptedString
								try {
									plain = Buffer.from(decryptedString, 'base64').toString('utf8')
								} catch {
									/* already utf8 */
								}
								if (params.expectSendId && !plain.includes(params.expectSendId)) {
									continue
								}
								clearTimeout(timer)
								return { ok: true, preview: plain.slice(0, 160), url }
							} catch (ex: any) {
								if (String(ex?.message ?? '').includes('No decryption key packets')) continue
							}
						} else if (data?.from && data?.text != null) {
							const plain = JSON.stringify(data)
							if (params.expectSendId && !plain.includes(params.expectSendId)) continue
							clearTimeout(timer)
							return { ok: true, preview: plain.slice(0, 160), url }
						}
					} catch {
						/* ignore non-JSON SSE lines */
					}
				}
			}
			errors.push(`${scheme} timeout`)
			clearTimeout(timer)
		} catch (e) {
			clearTimeout(timer)
			errors.push(`${scheme} ${e instanceof Error ? e.message : String(e)}`)
		}
	}
	return {
		ok: false,
		error: `no decryptable inbound (${errors.join('; ') || `timeout ${params.timeoutMs}ms`})`,
	}
}

async function main() {
	if (process.env.INSECURE_TLS === '1') {
		process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'
		console.warn(
			'[warn] INSECURE_TLS=1 — TLS verification disabled. Use only to separate cert issues from entry routing.',
		)
	}

	const args = parseArgs(process.argv)
	const results: StepResult[] = []

	console.log('=== CoNET DePIN message test (Tor-like: client ↔ entry only) ===')
	console.log(`mode: ${args.mode}`)
	console.log(`rpc: ${RPC}`)
	console.log(`AddressPGP: ${ADDRESS_PGP}`)
	console.log(`GuardianNodes: ${GUARDIAN_NODES}`)
	console.log(
		`client→entry schemes: ${entrySchemes().join('+')} | node↔node forward: HTTP:80 | never client→mailbox B`,
	)

	const provider = new ethers.JsonRpcProvider(RPC)
	const openpgp = await loadOpenPgp()

	const toPk = normalizePk(args.toPk)
	const fromPk = normalizePk(args.fromPk)
	let toAddress = args.to?.trim()
	if (!toAddress && toPk) toAddress = new ethers.Wallet(toPk).address
	if (!toAddress) {
		console.error('Need --to <EOA> or --to-pk <hex> for recipient')
		process.exit(2)
	}
	if (!ethers.isAddress(toAddress)) {
		console.error(`Invalid --to address: ${toAddress}`)
		process.exit(2)
	}
	toAddress = ethers.getAddress(toAddress)

	// --- Step 1: AddressPGP recipient ---
	const recip = await searchKey(provider, toAddress)
	const recipPub = recip.userPublicKeyArmoredB64
		? b64DecodeUtf8(recip.userPublicKeyArmoredB64)
		: null
	const routePub = recip.routePublicKeyArmoredB64
		? b64DecodeUtf8(recip.routePublicKeyArmoredB64)
		: null
	const mailboxB = recip.routeKeyID || null
	const step1: StepResult = {
		step: '1 AddressPGP.searchKey(recipient)',
		ok: Boolean(recip.userPgpKeyID && recipPub?.includes('BEGIN PGP') && recip.routeKeyID),
		detail: {
			to: toAddress,
			userPgpKeyID: recip.userPgpKeyID || '(empty)',
			hasUserPub: Boolean(recipPub?.includes('BEGIN PGP')),
			routeKeyID: mailboxB || '(empty)',
			hasRoutePub: Boolean(routePub?.includes('BEGIN PGP')),
			routeOnline: recip.routeOnline,
			privacy:
				'Clients must NOT HTTP to routeKeyID (mailbox B). Encrypt business msg to userPub; listen cmd to routePub; HTTP via entry A/C only.',
			hint: recip.routeOnline
				? 'mailbox B reports a listen session online (may be via entry C)'
				: 'routeOnline=false — recipient may not be listening yet',
		},
	}
	results.push(step1)
	printStep(step1)

	if (fromPk) {
		const from = new ethers.Wallet(fromPk).address
		const sender = await searchKey(provider, from)
		const step1b: StepResult = {
			step: '1b AddressPGP.searchKey(sender)',
			ok: Boolean(sender.userPgpKeyID && sender.userPublicKeyArmoredB64),
			detail: {
				from,
				userPgpKeyID: sender.userPgpKeyID || '(empty)',
				hasUserPub: Boolean(sender.userPublicKeyArmoredB64),
				routeKeyID: sender.routeKeyID || '(empty)',
				routeOnline: sender.routeOnline,
				hint: !sender.userPgpKeyID
					? 'sender missing chain PGP — biz may drop NEW chat sessions until sender registers'
					: 'ok',
			},
		}
		results.push(step1b)
		printStep(step1b)
	}

	// --- Step 2: entry A/C domains (exclude mailbox B) ---
	const allDomains = await fetchGuardianDomains(provider)
	const preferred = args.entry ? normDomain(args.entry) : null
	if (preferred && mailboxB && preferred === mailboxB) {
		console.warn(
			`[warn] --entry ${preferred} is mailbox B — ignoring for client privacy; picking other entries`,
		)
	}
	const sample = pickClientEntryDomains({
		allDomains,
		mailboxB,
		count: Math.max(ENTRY_COUNT, 4),
		preferred: preferred && preferred !== mailboxB ? preferred : null,
	})

	const entryHealth: Awaited<ReturnType<typeof entryGetHealth>>[] = []
	for (const d of sample) {
		for (const scheme of entrySchemes()) {
			entryHealth.push(await entryGetHealth(scheme, d))
		}
	}
	const healthyHttp = entryHealth.filter((x) => x.scheme === 'http' && x.ok).map((x) => x.domain)
	const healthyHttps = entryHealth.filter((x) => x.scheme === 'https' && x.ok).map((x) => x.domain)
	const healthyEntries = Array.from(new Set([...healthyHttps, ...healthyHttp]))
	const step2: StepResult = {
		step: '2 Entry A/C health (client-facing; mailbox B excluded)',
		ok: healthyEntries.length > 0,
		detail: {
			design:
				'Tor-like: probe/send/listen HTTP only to entries ≠ B. Encrypt targets: user PGP (send) / route B PGP (listen).',
			mailboxBExcluded: mailboxB,
			sampled: sample,
			healthyHttps,
			healthyHttp,
			results: entryHealth.map((x) => ({
				scheme: x.scheme,
				domain: x.domain,
				ok: x.ok,
				status: x.status ?? null,
				ms: x.ms,
				error: x.error ?? null,
				tlsHint: x.tlsHint ?? null,
			})),
		},
	}
	results.push(step2)
	printStep(step2)

	// --- Step 3: mailbox B resolved on-chain only (no client POST to B) ---
	const step3: StepResult = {
		step: '3 Mailbox B resolved (chain only; no client HTTP to B)',
		ok: Boolean(mailboxB && routePub?.includes('BEGIN PGP')),
		detail: {
			routeKeyID: mailboxB || '(empty)',
			hasRoutePub: Boolean(routePub?.includes('BEGIN PGP')),
			routeOnline: recip.routeOnline,
			note: 'Operator may SSH B for logs. Clients never GET/POST B for chat — that leaks IP to the mailbox.',
		},
	}
	results.push(step3)
	printStep(step3)

	if (args.mode === 'probe') {
		// Real OpenPGP (SilentPassUI shape) → entry A only. Fake armor → SI 404 is not an infra signal.
		if (!recipPub?.includes('BEGIN PGP')) {
			console.error('Recipient has no user PGP — cannot encrypt probe. Register Chat first.')
			process.exit(1)
		}
		const probeFrom = fromPk || ethers.Wallet.createRandom().privateKey
		const encrypted = await encryptSilentPassSendEnvelope({
			openpgp,
			recipientArmoredPub: recipPub,
			fromPk: probeFrom,
			text: 'probe',
		})
		const domainsForPost = shuffleTake(
			healthyEntries.length ? healthyEntries : sample,
			Math.min(3, Math.max(1, healthyEntries.length || sample.length)),
		)
		const postResults = []
		for (const d of domainsForPost) {
			postResults.push(await entryPostAnyScheme(d, encrypted.armored))
		}
		const anyPost2xx = postResults.some((r) => r.ok)
		const leakedB = Boolean(mailboxB && postResults.some((r) => r.domain === mailboxB))
		const step4: StepResult = {
			step: '4 Entry A POST /post (SilentPassUI encrypt → entry ≠ B)',
			ok: anyPost2xx && !leakedB,
			detail: {
				from: encrypted.from,
				sendId: encrypted.sendId,
				entriesTried: domainsForPost,
				mailboxBExcluded: mailboxB,
				leakedPostToMailboxB: leakedB,
				results: postResults.map((r) => ({
					scheme: r.scheme,
					domain: r.domain,
					url: r.url,
					ok: r.ok,
					status: r.status ?? null,
					ms: r.ms,
					error: r.error ?? null,
				})),
				note: anyPost2xx
					? 'Entry accepted valid OpenPGP (same shape as SilentPassUI sendMessage).'
					: 'No 2xx from entry /post — check SI on entry, not client→mailbox B.',
			},
		}
		results.push(step4)
		printStep(step4)

		const failed = results.filter((r) => !r.ok)
		console.log('\n=== Summary (probe) ===')
		console.log(`pass ${results.length - failed.length}/${results.length}`)
		if (failed.length) {
			console.log('failed steps:', failed.map((f) => f.step).join(' | '))
			process.exit(1)
		}
		console.log('OK: AddressPGP + entry-only POST path look healthy.')
		console.log('Next: send / roundtrip with --from-pk (and --to-pk + RECIPIENT_PGP_PRIVATE for roundtrip).')
		return
	}

	if (!fromPk) {
		console.error('send/roundtrip requires --from-pk <64-hex private key>')
		process.exit(2)
	}
	if (!recipPub?.includes('BEGIN PGP')) {
		console.error('Recipient has no on-chain user PGP — cannot encrypt. Merchant must register Chat first.')
		process.exit(1)
	}

	const text =
		args.text ||
		JSON.stringify({
			type: 'conet_depin_message_test_v1',
			sendId: `test-${Date.now()}`,
			createdAt: Date.now(),
			note: 'diagnostic ping — SilentPassUI sendMessage shape',
		})

	const encrypted = await encryptSilentPassSendEnvelope({
		openpgp,
		recipientArmoredPub: recipPub,
		fromPk,
		text,
	})
	const postTargets = shuffleTake(
		healthyEntries.length ? healthyEntries : sample,
		Math.min(6, ENTRY_COUNT),
	)
	if (mailboxB && postTargets.includes(mailboxB)) {
		console.error('BUG: mailbox B leaked into entry post targets — aborting')
		process.exit(1)
	}
	const sendResults = []
	for (const d of postTargets) {
		sendResults.push(await entryPostAnyScheme(d, encrypted.armored))
	}
	const sendOk = sendResults.some((r) => r.ok)
	const stepSend: StepResult = {
		step: '4 SilentPassUI sendMessage → Entry A (≠ mailbox B)',
		ok: sendOk,
		detail: {
			from: encrypted.from,
			to: toAddress,
			sendId: encrypted.sendId,
			entriesTried: postTargets,
			mailboxBExcluded: mailboxB,
			okCount: sendResults.filter((r) => r.ok).length,
			results: sendResults.map((r) => ({
				scheme: r.scheme,
				domain: r.domain,
				url: r.url,
				ok: r.ok,
				status: r.status ?? null,
				ms: r.ms,
				error: r.error ?? null,
			})),
			ciphertextBytes: encrypted.armored.length,
			forwardNote: 'After entry accept, A→B uses HTTP:80 between DePIN nodes.',
		},
	}
	results.push(stepSend)
	printStep(stepSend)

	if (args.mode === 'send') {
		const failed = results.filter((r) => !r.ok)
		console.log('\n=== Summary (send) ===')
		console.log(`pass ${results.length - failed.length}/${results.length}`)
		console.log(
			sendOk
				? 'Entry A accepted POST. If UI shows nothing: recipient must listen via entry C (not Messages for POS permission — Staff pending).'
				: 'All entry POSTs failed — check SI on entry A, not client→B.',
		)
		process.exit(sendOk && step1.ok ? 0 : 1)
	}

	// roundtrip
	if (!toPk) {
		console.error('roundtrip requires --to-pk so this process can sign mining listen as recipient EOA.')
		process.exit(2)
	}
	if (!routePub?.includes('BEGIN PGP')) {
		console.error('Recipient route public key missing — cannot encrypt mining listen command to B.')
		process.exit(1)
	}
	if (!mailboxB) {
		console.error('No mailbox B routeKeyID')
		process.exit(1)
	}

	const recipPgpPrivate =
		process.env.RECIPIENT_PGP_PRIVATE_ARMORED || process.env.TO_PGP_PRIVATE || ''
	if (!recipPgpPrivate.includes('BEGIN PGP PRIVATE')) {
		console.error(
			'roundtrip needs RECIPIENT_PGP_PRIVATE_ARMORED (or TO_PGP_PRIVATE) = armored private key matching chain userPublicKeyArmored for --to',
		)
		process.exit(sendOk ? 0 : 1)
	}

	const entryCCandidates = (healthyEntries.length ? healthyEntries : sample).filter(
		(d) => d !== mailboxB,
	)
	const entryC = shuffleTake(entryCCandidates.length ? entryCCandidates : sample, 1)[0]!
	if (entryC === mailboxB) {
		console.warn(
			'[warn] only mailbox B reachable as entry — listen will reveal client IP to B (privacy degraded)',
		)
	}

	const listenArmored = await encryptMiningListenCommand({
		openpgp,
		routeArmoredPub: routePub,
		walletPk: toPk,
	})

	console.log(
		`\n[…] Listening via entry C=${entryC} (encrypt→B=${mailboxB}) for up to ${LISTEN_MS}ms — client never connects to B…`,
	)

	const listenPromise = listenForMessage({
		openpgp,
		entryDomain: entryC,
		listenArmored,
		recipientPgpPrivateArmored: recipPgpPrivate,
		expectSendId: encrypted.sendId,
		timeoutMs: LISTEN_MS,
	})

	await new Promise((r) => setTimeout(r, 1_500))
	const resendEntry = postTargets.find((d) => d !== mailboxB) || postTargets[0]!
	const resend = await entryPostAnyScheme(resendEntry, encrypted.armored)
	console.log(`[…] Resend via entry A=${resendEntry}: ${resend.url} → ${resend.status ?? resend.error}`)

	const heard = await listenPromise
	const stepListen: StepResult = {
		step: '5 Listen via entry C→B + decrypt (SilentPassUI mining)',
		ok: heard.ok,
		detail: {
			entryC,
			mailboxB,
			listenUrl: heard.url ?? null,
			clientConnectedToMailboxB: entryC === mailboxB,
			preview: heard.preview ?? null,
			error: heard.error ?? null,
			forwardNote: 'C→B hop is HTTP:80 (SI socketForward). Encrypt target was B pubkey; HTTP host was C.',
		},
	}
	results.push(stepListen)
	printStep(stepListen)

	const failed = results.filter((r) => !r.ok)
	console.log('\n=== Summary (roundtrip) ===')
	console.log(`pass ${results.length - failed.length}/${results.length}`)
	if (failed.length) console.log('failed:', failed.map((f) => f.step).join(' | '))
	process.exit(failed.length ? 1 : 0)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
