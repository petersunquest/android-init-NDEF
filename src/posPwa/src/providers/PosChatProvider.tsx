import {
	createContext,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useRef,
	useState,
	type ReactNode,
} from 'react'
import {
	bootstrapPosChatSession,
	stopPosChatGossipListen,
} from '@/chat/posChatBootstrap'
import {
	extractInboundArmorHash,
	emitDualChatDeliveryReceipts,
	postMailboxDeliveryAck,
} from '@/chat/posChatDeliveryReceipt'
import { mergeHistoryBatchIntoStore, mirrorPosChatMessageToHistory } from '@/chat/posChatHistoryMirror'
import {
	inboundToPosChatMessage,
	parseInboundChatLine,
	parseInboundDeliveryReceiptLine,
} from '@/chat/posChatInbound'
import { sendPosChatTextMessage } from '@/chat/posChatSend'
import {
	ensureThread,
	loadPosChatStore,
	markOutboundDeliveredBySendId,
	markThreadRead,
	savePosChatStore,
	totalUnreadCount,
	upsertInboundMessage,
	upsertOutboundMessage,
} from '@/chat/posChatStore'
import { onHistoryBuffer } from '@/chat/posChatWorkerBridge'
import type { PosChatStoreSnapshot, PosChatThread } from '@/chat/posChatTypes'
import {
	isPosAppBackgrounded,
	notifyPosBackgroundChat,
	syncPosChatAppIconBadge,
} from '@/bridge/posNativeAppStateBridge'
import { usePosSession } from '@/providers/PosSessionProvider'
import { getSessionPrivateKeyHex, getSessionWalletAddress } from '@/wallet/posWalletService'

type PosChatContextValue = {
	threads: PosChatThread[]
	unreadTotal: number
	gossipReady: boolean
	gossipError: string | null
	refreshStore: () => void
	openOrCreateThread: (peerAddress: string, meta?: { peerTag?: string; peerName?: string }) => void
	markRead: (peerAddress: string) => void
	sendText: (peerAddress: string, text: string) => Promise<{ ok: boolean; error?: string }>
	getThread: (peerAddress: string) => PosChatThread | undefined
}

const PosChatContext = createContext<PosChatContextValue | null>(null)

export function usePosChat(): PosChatContextValue {
	const ctx = useContext(PosChatContext)
	if (!ctx) throw new Error('usePosChat requires PosChatProvider')
	return ctx
}

export function PosChatProvider({ children }: { children: ReactNode }) {
	const { bootPhase, walletAddress } = usePosSession()
	const eoa = (walletAddress || getSessionWalletAddress() || '').toLowerCase()
	const [snap, setSnap] = useState<PosChatStoreSnapshot>(() =>
		eoa ? loadPosChatStore(eoa) : { version: 1, threads: [], updatedAt: 0 },
	)
	const [gossipReady, setGossipReady] = useState(false)
	const [gossipError, setGossipError] = useState<string | null>(null)
	const prevUnreadRef = useRef(0)
	const activePeerRef = useRef<string | null>(null)
	const bootOnceRef = useRef(false)

	useEffect(() => {
		if (!eoa) {
			setSnap({ version: 1, threads: [], updatedAt: 0 })
			return
		}
		setSnap(loadPosChatStore(eoa))
	}, [eoa])

	const unreadTotal = useMemo(() => totalUnreadCount(snap), [snap])

	useEffect(() => {
		const prev = prevUnreadRef.current
		prevUnreadRef.current = unreadTotal
		syncPosChatAppIconBadge(unreadTotal)
		if (unreadTotal > prev && isPosAppBackgrounded()) {
			notifyPosBackgroundChat(unreadTotal)
		}
	}, [unreadTotal])

	const handleLine = useCallback(
		(line: string) => {
			if (!eoa) return
			const pk = getSessionPrivateKeyHex()
			const armorHash = extractInboundArmorHash(line)
			const receipt = parseInboundDeliveryReceiptLine(line)
			if (receipt) {
				setSnap((prev) => {
					const next = markOutboundDeliveredBySendId(prev, receipt.sendId)
					if (next !== prev) savePosChatStore(eoa, next)
					return next
				})
				if (armorHash && pk) {
					void postMailboxDeliveryAck({
						armorHash,
						sendId: receipt.sendId,
						walletPrivateKeyHex: pk,
					})
				}
				return
			}
			const parsed = parseInboundChatLine(line)
			if (!parsed) return
			const msg = inboundToPosChatMessage(parsed, eoa)
			if (!msg) return
			const viewing =
				activePeerRef.current?.toLowerCase() === msg.peerAddress.toLowerCase() &&
				!isPosAppBackgrounded()
			let ingested = false
			setSnap((prev) => {
				const next = upsertInboundMessage(prev, msg, { incrementUnread: !viewing })
				ingested = next !== prev
				if (ingested) savePosChatStore(eoa, next)
				return next
			})
			if (!ingested) return
			mirrorPosChatMessageToHistory(msg.peerAddress, msg, 'in')
			if (pk) {
				void emitDualChatDeliveryReceipts({
					armorHash,
					sendId: msg.sendId,
					senderEoa: msg.peerAddress,
					walletPrivateKeyHex: pk,
				})
			}
		},
		[eoa],
	)

	useEffect(() => {
		if (!eoa) return
		return onHistoryBuffer((batch) => {
			setSnap((prev) => {
				const next = mergeHistoryBatchIntoStore(prev, batch, eoa)
				if (next !== prev) savePosChatStore(eoa, next)
				return next
			})
		})
	}, [eoa])

	useEffect(() => {
		if (bootPhase !== 'home' || !eoa) {
			stopPosChatGossipListen()
			setGossipReady(false)
			bootOnceRef.current = false
			return
		}
		if (bootOnceRef.current) return
		bootOnceRef.current = true
		let cancelled = false
		void (async () => {
			const pk = getSessionPrivateKeyHex()
			if (!pk) {
				setGossipError('Wallet key unavailable')
				return
			}
			const result = await bootstrapPosChatSession({
				walletPrivateKeyHex: pk,
				onLine: handleLine,
			})
			if (cancelled) return
			if (result.ok) {
				setGossipReady(true)
				setGossipError(null)
			} else {
				setGossipReady(false)
				setGossipError(result.error ?? 'Chat listen failed')
				bootOnceRef.current = false
			}
		})()
		return () => {
			cancelled = true
		}
	}, [bootPhase, eoa, handleLine])

	useEffect(() => {
		return () => stopPosChatGossipListen()
	}, [])

	const refreshStore = useCallback(() => {
		if (!eoa) return
		setSnap(loadPosChatStore(eoa))
	}, [eoa])

	const openOrCreateThread = useCallback(
		(peerAddress: string, meta?: { peerTag?: string; peerName?: string }) => {
			if (!eoa) return
			setSnap((prev) => {
				const next = ensureThread(prev, peerAddress, meta)
				savePosChatStore(eoa, next)
				return next
			})
		},
		[eoa],
	)

	const markRead = useCallback(
		(peerAddress: string) => {
			if (!eoa) return
			activePeerRef.current = peerAddress
			setSnap((prev) => {
				const next = markThreadRead(prev, peerAddress)
				savePosChatStore(eoa, next)
				return next
			})
		},
		[eoa],
	)

	const sendText = useCallback(
		async (peerAddress: string, text: string) => {
			const pk = getSessionPrivateKeyHex()
			if (!pk || !eoa) return { ok: false, error: 'Wallet locked' }
			const trimmed = text.trim()
			if (!trimmed) return { ok: false, error: 'Empty message' }
			const result = await sendPosChatTextMessage({
				recipientEoa: peerAddress,
				text: trimmed,
				walletPrivateKeyHex: pk,
			})
			if (!result.ok) return { ok: false, error: 'Send failed' }
			const msg = {
				id: result.sendId,
				sendId: result.sendId,
				from: 'me' as const,
				text: trimmed,
				createdAt: result.createdAt,
				peerAddress,
				status: 'sent' as const,
			}
			setSnap((prev) => {
				const next = upsertOutboundMessage(prev, msg)
				savePosChatStore(eoa, next)
				return next
			})
			mirrorPosChatMessageToHistory(peerAddress, msg, 'out')
			return { ok: true }
		},
		[eoa],
	)

	const getThread = useCallback(
		(peerAddress: string) =>
			snap.threads.find((t) => t.peerAddress.toLowerCase() === peerAddress.toLowerCase()),
		[snap.threads],
	)

	const value = useMemo<PosChatContextValue>(
		() => ({
			threads: snap.threads,
			unreadTotal,
			gossipReady,
			gossipError,
			refreshStore,
			openOrCreateThread,
			markRead,
			sendText,
			getThread,
		}),
		[
			snap.threads,
			unreadTotal,
			gossipReady,
			gossipError,
			refreshStore,
			openOrCreateThread,
			markRead,
			sendText,
			getThread,
		],
	)

	return <PosChatContext.Provider value={value}>{children}</PosChatContext.Provider>
}
