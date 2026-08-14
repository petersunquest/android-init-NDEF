#!/usr/bin/env npx tsx
/**
 * CoNET DePIN UDP-forward diagnostic (same A/B/C privacy model as Chat).
 *
 *   subscribe — encrypt udp_subscribe to UDP server **user PGP**, POST via entry A ≠ B
 *   listen    — encrypt udp_listen to **B route PGP**, SSE via entry C ≠ B
 *   relay     — encrypt udp_relay to **B route PGP**, POST via entry D ≠ B
 *
 * Never POST to mailbox B. Never log Securitykey, private keys, or full ciphertext.
 *
 *   npx tsx scripts/testConetDepinUdp.ts subscribe --server 0x… --from-pk 0x… --session <uuid>
 *   npx tsx scripts/testConetDepinUdp.ts listen --server 0x… --from-pk 0x… --session <uuid>
 *   npx tsx scripts/testConetDepinUdp.ts relay --server-pk 0x… --session <uuid> --payload-b64 <aes>
 *
 * Env: CONET_RPC, ADDRESS_PGP, GUARDIAN_NODES, SCHEME=http|https|both, ENTRY_COUNT
 */
import { createRequire } from 'node:module'
import * as crypto from 'node:crypto'
import * as fs from 'node:fs'
import * as path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { ethers } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.join(__dirname, '..')

const RPC = process.env.CONET_RPC || 'https://rpc1.conet.network'
const ADDRESS_PGP =
	process.env.ADDRESS_PGP || '0x684b0ac760cEE9c9b85de36d69746420648Cf9e2'
const GUARDIAN_NODES =
	process.env.GUARDIAN_NODES || '0xBC6b53065b5647261396d002bDBA0d3396E0722f'
const ENTRY_COUNT = Math.max(1, Number(process.env.ENTRY_COUNT || 4))
const LISTEN_MS = Math.max(5_000, Number(process.env.LISTEN_MS || 30_000))
const SCHEME_MODE = (process.env.SCHEME || 'both').toLowerCase() as 'http' | 'https' | 'both'

type EntryScheme = 'http' | 'https'
type OpenPgpMod = typeof import('openpgp')

const FALLBACK_DOMAINS = [
	'9977E9A45187DD80',
	'B4CB0A41352E9BDF',
	'20AB90FE82D0E9E3',
	'AE85A2AEEC768225',
] as const

function entrySchemes(): EntryScheme[] {
	if (SCHEME_MODE === 'http') return ['http']
	if (SCHEME_MODE === 'https') return ['https']
	return ['https', 'http']
}

function entryUrl(scheme: EntryScheme, domain: string, suffix: string): string {
	return `${scheme}://${domain.toLowerCase()}.conet.network${suffix}`
}

function parseArgs(argv: string[]) {
	const mode = (argv[2] || 'help').toLowerCase()
	const out: Record<string, string> = { mode }
	for (let i = 3; i < argv.length; i++) {
		const a = argv[i]
		const n = argv[i + 1]
		if (a === '--server' && n) out.server = n
		if (a === '--from-pk' && n) out.fromPk = n
		if (a === '--server-pk' && n) out.serverPk = n
		if (a === '--session' && n) out.session = n
		if (a === '--payload-b64' && n) out.payloadB64 = n
		if (a === '--security-key' && n) out.securityKey = n
	}
	return out
}

async function loadOpenPgp(): Promise<OpenPgpMod> {
	try {
		return (await import('openpgp')) as OpenPgpMod
	} catch {
		/* fall through */
	}
	const candidates = [
		path.join(ROOT, 'src/bizSite/node_modules/openpgp/dist/node/openpgp.mjs'),
		path.join(ROOT, 'src/SilentPassUI/node_modules/openpgp/dist/node/openpgp.mjs'),
	]
	for (const p of candidates) {
		if (!fs.existsSync(p)) continue
		return (await import(pathToFileURL(p).href)) as OpenPgpMod
	}
	const req = createRequire(path.join(ROOT, 'src/bizSite/package.json'))
	return req('openpgp') as OpenPgpMod
}

async function searchKey(provider: ethers.Provider, wallet: string) {
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
	}
}

function decodeArmored(b64: string): string {
	return Buffer.from(b64, 'base64').toString('utf8')
}

async function fetchGuardianDomains(provider: ethers.Provider): Promise<string[]> {
	const abi = [
		'function getAllNodes(uint256 start,uint256 length) view returns (tuple(uint256 id,string PGP,string PGPKey,string ip_addr,string regionName)[])',
	]
	const c = new ethers.Contract(GUARDIAN_NODES, abi, provider)
	try {
		const page = (await c.getAllNodes(0, 200)) as { PGPKey?: string }[]
		const domains = Array.from(
			new Set(
				page
					.map((n) => String(n?.PGPKey || '').replace(/[^0-9a-fA-F]/g, '').toUpperCase())
					.filter((d) => d.length >= 8),
			),
		)
		if (domains.length) return domains
	} catch (e) {
		console.warn('[warn] getAllNodes failed', e instanceof Error ? e.message : e)
	}
	return [...FALLBACK_DOMAINS]
}

async function pickHealthyEntries(
	domains: string[],
	excludeRouteKey: string,
	need: number,
): Promise<{ scheme: EntryScheme; domain: string }[]> {
	const exclude = excludeRouteKey.toUpperCase()
	const picked: { scheme: EntryScheme; domain: string }[] = []
	for (const domain of domains) {
		if (domain.toUpperCase() === exclude) continue
		for (const scheme of entrySchemes()) {
			try {
				const res = await fetch(entryUrl(scheme, domain, '/'), {
					method: 'GET',
					signal: AbortSignal.timeout(4000),
					cache: 'no-store',
				})
				if (res.status > 0 && res.status < 500) {
					picked.push({ scheme, domain })
					break
				}
			} catch {
				/* try next scheme */
			}
		}
		if (picked.length >= need) break
	}
	return picked
}

async function encryptCommand(openpgp: OpenPgpMod, armoredPub: string, command: object, signer: ethers.Wallet) {
	const message = JSON.stringify(command)
	const signMessage = await signer.signMessage(message)
	const literal = Buffer.from(JSON.stringify({ message, signMessage })).toString('base64')
	const encrypted = await openpgp.encrypt({
		message: await openpgp.createMessage({ text: literal }),
		encryptionKeys: await openpgp.readKey({ armoredKey: armoredPub }),
		config: { preferredCompressionAlgorithm: openpgp.enums.compression.zlib },
	})
	return String(encrypted)
}

async function postArmored(
	entry: { scheme: EntryScheme; domain: string },
	armored: string,
	timeoutMs = 15_000,
): Promise<{ ok: boolean; status?: number; body?: string; error?: string }> {
	const url = entryUrl(entry.scheme, entry.domain, '/post')
	try {
		const res = await fetch(url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ data: armored }),
			signal: AbortSignal.timeout(timeoutMs),
		})
		const body = await res.text()
		return { ok: res.ok, status: res.status, body: body.slice(0, 400) }
	} catch (e) {
		return { ok: false, error: e instanceof Error ? e.message : String(e) }
	}
}

function generateSessionId(): string {
	return crypto.randomUUID()
}

function generateSecurityKeyB64(): string {
	return crypto.randomBytes(32).toString('base64')
}

async function main() {
	const args = parseArgs(process.argv)
	if (args.mode === 'help' || args.mode === '-h') {
		console.log(`CoNET DePIN UDP forward probe
  subscribe --server <EOA> --from-pk <hex> [--session id] [--security-key b64]
  listen    --server <EOA> --from-pk <hex> --session <id>
  relay     --server-pk <hex> --session <id> --payload-b64 <aes>
Entry A/C/D ≠ mailbox B. See conet-depin-udp-forward-protocol.mdc`)
		return
	}

	const provider = new ethers.JsonRpcProvider(RPC)
	const openpgp = await loadOpenPgp()
	const domains = await fetchGuardianDomains(provider)

	if (args.mode === 'subscribe') {
		if (!args.server || !args.fromPk) throw new Error('subscribe needs --server and --from-pk')
		const client = new ethers.Wallet(args.fromPk)
		const sessionId = args.session || generateSessionId()
		const securityKey = args.securityKey || generateSecurityKeyB64()
		const row = await searchKey(provider, args.server)
		if (!row.userPublicKeyArmoredB64) throw new Error('UDP server has no user PGP — regiestChatRoute first')
		const entries = await pickHealthyEntries(domains, row.routeKeyID, ENTRY_COUNT)
		if (!entries.length) throw new Error('no healthy entry A ≠ B')
		const command = {
			command: 'udp_subscribe',
			walletAddress: client.address.toLowerCase(),
			udpServerWallet: ethers.getAddress(args.server).toLowerCase(),
			sessionId,
			algorithm: 'aes-256-gcm',
			Securitykey: securityKey,
			timestamp: Math.floor(Date.now() / 1000),
		}
		const armored = await encryptCommand(openpgp, decodeArmored(row.userPublicKeyArmoredB64), command, client)
		const posted = await postArmored(entries[0], armored)
		console.log(
			JSON.stringify(
				{
					ok: posted.ok,
					sessionId,
					client: client.address,
					udpServer: args.server,
					entryA: `${entries[0].scheme}://${entries[0].domain}`,
					mailboxB: row.routeKeyID,
					status: posted.status,
					securityKeySet: true,
				},
				null,
				2,
			),
		)
		return
	}

	if (args.mode === 'listen') {
		if (!args.server || !args.fromPk || !args.session) {
			throw new Error('listen needs --server --from-pk --session')
		}
		const client = new ethers.Wallet(args.fromPk)
		const row = await searchKey(provider, args.server)
		if (!row.routePublicKeyArmoredB64) throw new Error('UDP server has no route PGP')
		const entries = await pickHealthyEntries(domains, row.routeKeyID, 2)
		if (!entries.length) throw new Error('no healthy entry C ≠ B')
		const command = {
			command: 'udp_listen',
			listenKind: 'udp',
			walletAddress: client.address.toLowerCase(),
			udpServerWallet: ethers.getAddress(args.server).toLowerCase(),
			sessionId: args.session,
			timestamp: Math.floor(Date.now() / 1000),
		}
		const armored = await encryptCommand(openpgp, decodeArmored(row.routePublicKeyArmoredB64), command, client)
		const url = entryUrl(entries[0].scheme, entries[0].domain, '/post')
		console.log(
			JSON.stringify(
				{
					opening: true,
					sessionId: args.session,
					entryC: `${entries[0].scheme}://${entries[0].domain}`,
					mailboxB: row.routeKeyID,
					listenMs: LISTEN_MS,
				},
				null,
				2,
			),
		)
		const res = await fetch(url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ data: armored }),
			signal: AbortSignal.timeout(LISTEN_MS),
		})
		const text = await res.text()
		console.log(JSON.stringify({ status: res.status, preview: text.slice(0, 500) }, null, 2))
		return
	}

	if (args.mode === 'relay') {
		if (!args.serverPk || !args.session || !args.payloadB64) {
			throw new Error('relay needs --server-pk --session --payload-b64')
		}
		const server = new ethers.Wallet(args.serverPk)
		const row = await searchKey(provider, server.address)
		if (!row.routePublicKeyArmoredB64) throw new Error('server has no route PGP')
		const entries = await pickHealthyEntries(domains, row.routeKeyID, 2)
		if (!entries.length) throw new Error('no healthy entry D ≠ B')
		const command = {
			command: 'udp_relay',
			walletAddress: server.address.toLowerCase(),
			sessionId: args.session,
			payload: args.payloadB64,
			timestamp: Math.floor(Date.now() / 1000),
		}
		const armored = await encryptCommand(openpgp, decodeArmored(row.routePublicKeyArmoredB64), command, server)
		const posted = await postArmored(entries[0], armored)
		console.log(
			JSON.stringify(
				{
					ok: posted.ok,
					sessionId: args.session,
					entryD: `${entries[0].scheme}://${entries[0].domain}`,
					status: posted.status,
					body: posted.body,
				},
				null,
				2,
			),
		)
		return
	}

	throw new Error(`unknown mode ${args.mode}`)
}

main().catch((e) => {
	console.error(e instanceof Error ? e.message : e)
	process.exit(1)
})
