/**
 * POS PWA bridge to the vendored Beamio Chat SDK worker.
 * Listen / send / mailbox ACK / encrypted history run in the Worker.
 * Host still parses inbound lines (POS permission, receipts, bubbles).
 */
import { Wallet } from 'ethers'
import { CONET_RPC } from '@/constants'
import { CONET_ADDRESS_PGP_MANAGER, CONET_CHAT_INDEX_REGISTRY } from '@/conet/constants'
import { createBeamioChatClient } from '@/vendor/beamio-chat-sdk'
import type {
	BeamioChatConfig,
	ChatRoute,
	HistoryBufferEvent,
	HistoryEntry,
	HistoryLoadOptions,
	NodeInfo,
	SendMessageOptions,
} from '@/vendor/beamio-chat-sdk/types'

const IPFS_BASE_URL = 'https://ipfs.conet.network/api'
const BEAMIO_API_BASE_URL = 'https://beamio.app/api'

type ChatWorkerClient = ReturnType<typeof createBeamioChatClient>

let activeClient: ChatWorkerClient | null = null

export type PosChatListenContext = {
	routerArmoredPublicKey: string
	nodes: NodeInfo[]
	mailboxDomains: Set<string>
}

let listenContext: PosChatListenContext | null = null

const historyBufferListeners = new Set<(batch: HistoryBufferEvent) => void>()
let pendingHistoryLoad: HistoryLoadOptions | true | null = null
let historyLoadInFlight: Promise<void> | null = null

export const onHistoryBuffer = (cb: (batch: HistoryBufferEvent) => void): (() => void) => {
	historyBufferListeners.add(cb)
	return () => {
		historyBufferListeners.delete(cb)
	}
}

export function getPosChatListenContext(): PosChatListenContext | null {
	return listenContext
}

const runHistoryLoad = async (options?: HistoryLoadOptions): Promise<void> => {
	const client = activeClient
	if (!client) return
	try {
		await client.history.load(options)
	} catch (ex) {
		console.warn('[POS Chat] history.load failed:', (ex as Error)?.message ?? String(ex))
	}
}

export const loadWorkerHistory = async (options?: HistoryLoadOptions): Promise<void> => {
	if (!activeClient) {
		pendingHistoryLoad = options ?? true
		console.info('[POS Chat] history load queued — worker not ready yet')
		return
	}
	const queued = pendingHistoryLoad
	pendingHistoryLoad = null
	const opts = options ?? (queued && queued !== true ? queued : undefined)
	const run = runHistoryLoad(opts)
	historyLoadInFlight = run
	try {
		await run
	} finally {
		if (historyLoadInFlight === run) historyLoadInFlight = null
	}
}

export const appendWorkerHistory = async (entry: Omit<HistoryEntry, 'seq'>): Promise<void> => {
	if (!activeClient) return
	try {
		await activeClient.history.append(entry)
	} catch {
		/* best-effort */
	}
}

function makeGossipWorker(): Worker {
	return new Worker(new URL('../vendor/beamio-chat-sdk/worker/entry.ts', import.meta.url), {
		type: 'module',
		name: 'beamio-chat-gossip',
	})
}

export interface StartWorkerGossipParams {
	ownRouteArmoredPublicKey: string
	privateKeyHex: string
	pgpPrivateKeyArmored: string
	pgpPublicKeyArmored: string
	nodes: NodeInfo[]
	rootSignal: AbortSignal
	onLine: (line: string) => void
	onActivity: () => void
	onLog?: (level: 'info' | 'warn' | 'error', message: string) => void
}

export const stopWorkerGossip = (): void => {
	listenContext = null
	if (activeClient) {
		try {
			activeClient.destroy()
		} catch {
			/* ignore */
		}
		activeClient = null
	}
}

export const isWorkerGossipActive = (): boolean => activeClient !== null

export async function sendWorkerChatPayload(
	to: ChatRoute,
	payload: string,
	opts?: SendMessageOptions,
): Promise<{ ok: boolean; sendId: string }> {
	const sendId = opts?.sendId || `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
	if (!activeClient) return { ok: false, sendId }
	try {
		const r = await activeClient.sendMessage(to, payload, { ...opts, sendId })
		return { ok: true, sendId: r.sendId }
	} catch (ex) {
		console.warn('[POS Chat] worker send failed:', (ex as Error)?.message ?? String(ex))
		return { ok: false, sendId }
	}
}

export async function postWorkerMailboxCommand(
	routerArmoredPublicKey: string,
	command: Record<string, unknown>,
): Promise<boolean> {
	if (!activeClient) return false
	try {
		return await activeClient.postMailboxCommand(routerArmoredPublicKey, command)
	} catch {
		return false
	}
}

export const startWorkerGossipListen = async (p: StartWorkerGossipParams): Promise<boolean> => {
	stopWorkerGossip()
	if (p.rootSignal.aborted) return false

	const eoaAddress = deriveEoaAddress(p.privateKeyHex)
	const nodeSnapshot = p.nodes.slice()
	const mailboxDomains = new Set(
		nodeSnapshot
			.filter((n) => normalizeArmored(n.armoredPublicKey) === normalizeArmored(p.ownRouteArmoredPublicKey))
			.map((n) => n.domain),
	)

	const config: BeamioChatConfig = {
		identity: {
			eoaAddress,
			privateKeyHex: p.privateKeyHex,
			pgpPrivateKeyArmored: p.pgpPrivateKeyArmored,
			pgpPassphrase: '',
			pgpPublicKeyArmored: p.pgpPublicKeyArmored,
			ownRouteArmoredPublicKey: p.ownRouteArmoredPublicKey,
		},
		conetRpcUrl: CONET_RPC,
		addressPgpContractAddress: CONET_ADDRESS_PGP_MANAGER,
		getNodes: async () => nodeSnapshot,
		ipfsBaseUrl: IPFS_BASE_URL,
		chatIndexRegistryAddress: CONET_CHAT_INDEX_REGISTRY,
		apiBaseUrl: BEAMIO_API_BASE_URL,
	}

	const client = createBeamioChatClient(config, { workerFactory: makeGossipWorker })
	activeClient = client
	listenContext = {
		routerArmoredPublicKey: p.ownRouteArmoredPublicKey,
		nodes: nodeSnapshot,
		mailboxDomains,
	}

	const unsubs: Array<() => void> = []
	unsubs.push(
		client.on('message', (env) => {
			if (p.rootSignal.aborted) return
			p.onActivity()
			if (!env.line) return
			p.onLine(attachArmorHashToLine(env.line, env.armorHash))
		}),
	)
	unsubs.push(
		client.on('status', (st) => {
			if (st.status === 'listening') p.onActivity()
			p.onLog?.('info', `gossip status: ${st.status}${st.detail ? ` (${st.detail})` : ''}`)
		}),
	)
	unsubs.push(
		client.on('log', (l) => {
			p.onLog?.(l.level, l.message)
		}),
	)
	unsubs.push(
		client.history.onBuffer((batch) => {
			if (p.rootSignal.aborted) return
			for (const cb of historyBufferListeners) {
				try {
					cb(batch)
				} catch {
					/* ignore */
				}
			}
		}),
	)

	const teardown = () => {
		for (const u of unsubs.splice(0)) {
			try {
				u()
			} catch {
				/* ignore */
			}
		}
		if (activeClient === client) {
			try {
				client.destroy()
			} catch {
				/* ignore */
			}
			activeClient = null
		}
		if (listenContext?.routerArmoredPublicKey === p.ownRouteArmoredPublicKey) {
			listenContext = null
		}
		p.rootSignal.removeEventListener('abort', teardown)
	}
	p.rootSignal.addEventListener('abort', teardown)

	try {
		await client.init()
		if (p.rootSignal.aborted) {
			teardown()
			return false
		}
		p.onLog?.('info', 'chat history: worker ready — loading on-chain/IPFS index')
		void loadWorkerHistory()
		return true
	} catch (ex) {
		p.onLog?.('error', `worker gossip init failed: ${(ex as Error)?.message ?? String(ex)}`)
		teardown()
		return false
	}
}

function attachArmorHashToLine(line: string, armorHash?: string): string {
	const hash = (armorHash || '').trim().toLowerCase()
	if (!/^0x[0-9a-f]{64}$/.test(hash)) return line
	try {
		const obj = JSON.parse(line) as { _beamioPgpArmorHash?: unknown }
		if (obj && typeof obj === 'object' && !obj._beamioPgpArmorHash) {
			obj._beamioPgpArmorHash = hash
			return JSON.stringify(obj)
		}
	} catch {
		/* keep original line */
	}
	return line
}

function normalizeArmored(v?: string): string {
	return (v || '').replace(/\r/g, '').trim()
}

function deriveEoaAddress(privateKeyHex: string): string {
	try {
		const hex = privateKeyHex.startsWith('0x') ? privateKeyHex : `0x${privateKeyHex}`
		return new Wallet(hex).address
	} catch {
		return ''
	}
}
