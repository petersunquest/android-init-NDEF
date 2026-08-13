import {
	createMessage,
	decrypt,
	decryptKey,
	encrypt,
	enums,
	readKey,
	readMessage,
	readPrivateKey,
	type PrivateKey,
} from 'openpgp'
import { Wallet } from 'ethers'
import {
	fetchCoNETGossipNodes,
	getRandomGossipNode,
	type GossipNodeInfo,
} from '@/conet/guardianNodes'
import { normalizePrivateKeyHex, randomBase64Bytes, utf8ToBase64, fromBase64Utf8 } from '@/conet/crypto'

type ListenCallback = (err: string | undefined, data: string | undefined) => void

let currentAbort: AbortController | null = null

const gossipHealthyCache = new Map<string, number>()
const GOSSIP_HEALTH_TTL_MS = 120_000

function markHealthy(domain: string) {
	gossipHealthyCache.set(domain, Date.now() + GOSSIP_HEALTH_TTL_MS)
}

function markBad(domain: string) {
	gossipHealthyCache.delete(domain)
}

function normalizeArmored(v?: string) {
	return (v || '').replace(/\r/g, '').trim()
}

function pickRouteNodes(nodes: GossipNodeInfo[], routerArmored: string) {
	const target = normalizeArmored(routerArmored)
	if (!target) return []
	return nodes.filter((n) => normalizeArmored(n.armoredPublicKey) === target)
}

async function probeNode(node: GossipNodeInfo, timeoutMs = 4_000): Promise<boolean> {
	const url = `https://${node.domain}.conet.network/`
	const ctrl = new AbortController()
	const t = setTimeout(() => ctrl.abort(), timeoutMs)
	try {
		const res = await fetch(url, { method: 'GET', headers: { Accept: 'text/html' }, signal: ctrl.signal })
		if (res.status > 0 && res.status < 500) {
			markHealthy(node.domain)
			return true
		}
	} catch {
		/* bad */
	} finally {
		clearTimeout(t)
	}
	markBad(node.domain)
	return false
}

async function pickHealthyEntries(nodes: GossipNodeInfo[]): Promise<GossipNodeInfo[]> {
	const cached = nodes.filter((n) => (gossipHealthyCache.get(n.domain) || 0) > Date.now())
	if (cached.length >= 2) return cached
	const sample = [...nodes].sort(() => Math.random() - 0.5).slice(0, 8)
	const results = await Promise.all(sample.map((n) => probeNode(n)))
	const ok = sample.filter((_, i) => results[i])
	return ok.length ? ok : nodes.slice(0, 4)
}

function startGossipSse(
	nodes: GossipNodeInfo[],
	body: string,
	callback: ListenCallback,
	rootSignal: AbortSignal,
	reconnectAttempt = 0,
): void {
	if (rootSignal.aborted || !nodes.length) return
	const node = getRandomGossipNode(nodes)!
	const url = `https://${node.domain}.conet.network/post`
	const controller = new AbortController()
	const onRootAbort = () => controller.abort('root_stop')
	rootSignal.addEventListener('abort', onRootAbort)

	let relaunching = false
	const relaunch = (reason?: string) => {
		if (rootSignal.aborted || relaunching) return
		relaunching = true
		rootSignal.removeEventListener('abort', onRootAbort)
		try {
			controller.abort('relaunching')
		} catch {
			/* ignore */
		}
		const next = reconnectAttempt + 1
		const delay = Math.min(30_000, Math.round(2_000 * Math.pow(1.6, Math.min(next, 8))))
		setTimeout(() => {
			if (rootSignal.aborted) return
			startGossipSse(nodes, body, callback, rootSignal, next)
		}, delay)
		void reason
	}

	const connectTimer = setTimeout(() => controller.abort('connect_timeout'), 12_000)
	let idleTimer: ReturnType<typeof setTimeout> | null = null
	const resetIdle = () => {
		if (idleTimer) clearTimeout(idleTimer)
		idleTimer = setTimeout(() => controller.abort('idle_timeout'), 90_000)
	}

	void (async () => {
		let reader: ReadableStreamDefaultReader<Uint8Array> | undefined
		try {
			const res = await fetch(url, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json;charset=UTF-8',
					Accept: 'text/event-stream',
					Connection: 'keep-alive',
				},
				body,
				signal: controller.signal,
				cache: 'no-store',
			})
			clearTimeout(connectTimer)
			if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`)
			markHealthy(node.domain)
			console.info(`[POS Chat] SSE connected ${node.domain}`)
			reader = res.body.getReader()
			const decoder = new TextDecoder('utf-8')
			let buffer = ''
			let first = true
			resetIdle()

			while (true) {
				if (rootSignal.aborted) throw new Error('root_stop')
				const { value, done } = await reader.read()
				if (done) break
				resetIdle()
				buffer += decoder.decode(value, { stream: true })
				let idx: number
				while ((idx = buffer.indexOf('\r\n\r\n')) !== -1 || (idx = buffer.indexOf('\n\n')) !== -1) {
					const isFour = buffer.slice(idx, idx + 4) === '\r\n\r\n'
					const sep = isFour ? 4 : 2
					const block = buffer.slice(0, idx)
					buffer = buffer.slice(idx + sep)
					const dataLines = block
						.split('\n')
						.filter((l) => l.startsWith('data:'))
						.map((l) => l.slice(5).trimStart())
					const payload = (dataLines.length ? dataLines.join('\n') : block).trim()
					if (!payload) continue
					if (first) {
						first = false
						continue
					}
					callback(undefined, payload)
				}
			}
			relaunch('server_closed')
		} catch (err: unknown) {
			clearTimeout(connectTimer)
			if (idleTimer) clearTimeout(idleTimer)
			const msg = err instanceof Error ? err.message : String(err)
			if (msg === 'root_stop' || rootSignal.aborted) return
			if (msg !== 'relaunching' && msg !== 'AbortError') {
				callback(msg, undefined)
			}
			relaunch(msg)
		} finally {
			rootSignal.removeEventListener('abort', onRootAbort)
			if (reader) {
				try {
					await reader.cancel()
					reader.releaseLock()
				} catch {
					/* ignore */
				}
			}
		}
	})()
}

export function stopPosChatGossipListen(): void {
	if (!currentAbort) return
	try {
		currentAbort.abort('stop')
	} catch {
		/* ignore */
	}
	currentAbort = null
}

export async function startPosChatGossipListen(params: {
	routerArmoredPublicKey: string
	walletPrivateKeyHex: string
	pgpPrivateKeyArmored: string
	pgpPublicKeyArmored: string
	onLine: (line: string) => void
}): Promise<boolean> {
	stopPosChatGossipListen()
	const pk = normalizePrivateKeyHex(params.walletPrivateKeyHex)
	if (!pk || !params.routerArmoredPublicKey?.trim() || !params.pgpPrivateKeyArmored?.trim()) {
		return false
	}

	const nodes = await fetchCoNETGossipNodes()
	if (!nodes.length) {
		console.warn('[POS Chat] no Guardian nodes')
		return false
	}

	const routeNodes = pickRouteNodes(nodes, params.routerArmoredPublicKey)
	const mailboxDomains = new Set(
		(routeNodes.length ? routeNodes : []).map((n) => n.domain),
	)
	const entryCandidates = nodes.filter((n) => !mailboxDomains.has(n.domain))
	const healthy = await pickHealthyEntries(entryCandidates.length ? entryCandidates : nodes)
	if (!healthy.length) {
		console.warn('[POS Chat] no healthy entry C')
		return false
	}

	const wallet = new Wallet(`0x${pk}`)
	const securityKey = randomBase64Bytes(16)
	const command = {
		command: 'mining',
		listenKind: 'chat',
		walletAddress: wallet.address,
		algorithm: 'aes-256-cbc',
		Securitykey: securityKey,
	}
	const message = JSON.stringify(command)
	const signMessage = await wallet.signMessage(message)
	const encryptionKeys = await readKey({ armoredKey: params.routerArmoredPublicKey })
	const pgpMsg = await createMessage({
		text: utf8ToBase64(JSON.stringify({ message, signMessage })),
	})
	const postData = await encrypt({
		message: pgpMsg,
		encryptionKeys,
		config: { preferredCompressionAlgorithm: enums.compression.zlib },
	})

	let decryptedPrivateKey: PrivateKey
	const pkObj = await readPrivateKey({ armoredKey: params.pgpPrivateKeyArmored })
	decryptedPrivateKey = pkObj.isDecrypted()
		? pkObj
		: await decryptKey({ privateKey: pkObj, passphrase: '' })

	const myController = new AbortController()
	currentAbort = myController

	startGossipSse(
		healthy,
		JSON.stringify({ data: postData }),
		async (err, data) => {
			if (myController.signal.aborted) return
			if (err || !data) return
			try {
				const parsed = JSON.parse(data) as { data?: string; from?: string; text?: unknown }
				if (parsed?.data && /^-----BEGIN PGP MESSAGE-----/i.test(parsed.data)) {
					const msg = await readMessage({ armoredMessage: parsed.data })
					const { data: decrypted } = await decrypt({
						message: msg,
						decryptionKeys: decryptedPrivateKey,
					})
					const decryptedString = typeof decrypted === 'string' ? decrypted : String(decrypted)
					let line: string
					try {
						line = fromBase64Utf8(decryptedString)
					} catch {
						line = decryptedString
					}
					params.onLine(line)
				} else if (parsed?.from && parsed?.text != null) {
					params.onLine(JSON.stringify(parsed))
				}
			} catch (ex: unknown) {
				const m = ex instanceof Error ? ex.message : String(ex)
				if (m.includes('No decryption key packets found')) return
				console.warn('[POS Chat] parse', m)
			}
		},
		myController.signal,
	)
	return true
}
