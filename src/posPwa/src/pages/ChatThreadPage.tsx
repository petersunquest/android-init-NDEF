import { ArrowUp, ExternalLink, Loader2 } from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { openExternalUrl } from '@/bridge/cashTreesScanBridge'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenFooter, PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosChat } from '@/providers/PosChatProvider'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'

const URL_RE = /(https?:\/\/[^\s<>"']+)/gi

function fmtAddr(a: string) {
	if (!a || a.length < 10) return a
	return `${a.slice(0, 6)}…${a.slice(-4)}`
}

function MessageBody({ text, mine }: { text: string; mine: boolean }) {
	const parts = text.split(URL_RE)
	return (
		<p
			className={`whitespace-pre-wrap break-words text-[15px] leading-snug ${
				mine ? 'text-white' : 'text-slate-800'
			}`}
		>
			{parts.map((part, i) => {
				if (/^https?:\/\//i.test(part)) {
					return (
						<button
							key={`${i}-${part.slice(0, 24)}`}
							type="button"
							className={`inline-flex items-center gap-0.5 underline underline-offset-2 ${
								mine ? 'text-white/95' : 'text-[#1562f0]'
							}`}
							onClick={() => openExternalUrl(part)}
						>
							<span className="max-w-[14rem] truncate">{part}</span>
							<ExternalLink className="h-3 w-3 shrink-0" aria-hidden />
						</button>
					)
				}
				return <span key={i}>{part}</span>
			})}
		</p>
	)
}

export function ChatThreadPage() {
	const { peerAddress = '' } = useParams<{ peerAddress: string }>()
	const navigate = useNavigate()
	const { getThread, markRead, sendText, openOrCreateThread } = usePosChat()
	const [draft, setDraft] = useState('')
	const [sending, setSending] = useState(false)
	const [sendError, setSendError] = useState<string | null>(null)
	const bottomRef = useRef<HTMLDivElement>(null)
	const decodedPeer = useMemo(() => {
		try {
			return decodeURIComponent(peerAddress)
		} catch {
			return peerAddress
		}
	}, [peerAddress])

	const thread = getThread(decodedPeer)

	useEffect(() => {
		if (!decodedPeer || !/^0x[0-9a-fA-F]{40}$/i.test(decodedPeer)) {
			navigate(POS_HOME_ROUTES.chat, { replace: true })
			return
		}
		openOrCreateThread(decodedPeer)
		markRead(decodedPeer)
	}, [decodedPeer, markRead, navigate, openOrCreateThread])

	useEffect(() => {
		bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
	}, [thread?.messages.length])

	const title =
		(thread?.peerTag || '').trim() ||
		(thread?.peerName || '').trim() ||
		fmtAddr(decodedPeer)

	const onSend = async () => {
		if (sending || !draft.trim()) return
		setSending(true)
		setSendError(null)
		const r = await sendText(decodedPeer, draft)
		setSending(false)
		if (!r.ok) {
			setSendError(r.error || 'Send failed')
			return
		}
		setDraft('')
	}

	return (
		<PosScreenShell>
			<PosScreenHeader className="border-b border-slate-100 px-4 pb-3">
				<div className="relative flex min-h-9 items-center justify-center">
					<BeamioCircularBackButton
						className="absolute left-0 top-0"
						onClick={() => navigate(POS_HOME_ROUTES.chat)}
					/>
					<div className="max-w-[70%] truncate text-center">
						<p className="truncate text-[16px] font-bold text-[#0F172A]">{title}</p>
						<p className="truncate text-[11px] text-slate-400">{fmtAddr(decodedPeer)}</p>
					</div>
				</div>
			</PosScreenHeader>

			<PosScreenMain className="overflow-y-auto bg-slate-50/80 px-3 py-3">
				<div className="mx-auto flex w-full max-w-lg flex-col gap-2">
					{(thread?.messages || []).map((m) => {
						const mine = m.from === 'me'
						return (
							<div key={m.id} className={`flex ${mine ? 'justify-end' : 'justify-start'}`}>
								<div
									className={`max-w-[82%] rounded-2xl px-3.5 py-2 shadow-sm ${
										mine
											? 'rounded-br-md bg-[#1562f0]'
											: 'rounded-bl-md border border-slate-100 bg-white'
									}`}
								>
									<MessageBody text={m.text} mine={mine} />
									<p
										className={`mt-1 text-[10px] ${
											mine ? 'text-white/70' : 'text-slate-400'
										}`}
									>
										{new Date(m.createdAt).toLocaleTimeString(undefined, {
											hour: 'numeric',
											minute: '2-digit',
										})}
									</p>
								</div>
							</div>
						)
					})}
					<div ref={bottomRef} />
				</div>
			</PosScreenMain>

			<PosScreenFooter className="border-t border-slate-100 !px-3 !py-2">
				{sendError ? (
					<p className="mb-1.5 text-center text-xs text-amber-600" role="alert">
						{sendError}
					</p>
				) : null}
				<form
					id="pos-chat-thread-form"
					className="flex items-end gap-2"
					onSubmit={(e) => {
						e.preventDefault()
						void onSend()
					}}
				>
					<textarea
						value={draft}
						onChange={(e) => setDraft(e.target.value)}
						rows={1}
						enterKeyHint="send"
						placeholder="Message"
						className="max-h-28 min-h-[42px] flex-1 resize-none rounded-[22px] border border-slate-200 bg-white px-4 py-2.5 text-[15px] text-slate-800 outline-none focus:border-[#1562f0]/40 focus:ring-2 focus:ring-[#1562f0]/15"
						onKeyDown={(e) => {
							if (e.key === 'Enter' && !e.shiftKey) {
								e.preventDefault()
								void onSend()
							}
						}}
					/>
					<button
						type="submit"
						disabled={sending || !draft.trim()}
						aria-busy={sending}
						aria-label="Send"
						className="inline-flex h-[42px] w-[42px] shrink-0 items-center justify-center rounded-full bg-[#1562f0] text-white disabled:opacity-40"
					>
						{sending ? (
							<Loader2 className="h-5 w-5 animate-spin" aria-hidden />
						) : (
							<ArrowUp className="h-5 w-5" strokeWidth={2.5} aria-hidden />
						)}
					</button>
				</form>
			</PosScreenFooter>
		</PosScreenShell>
	)
}
