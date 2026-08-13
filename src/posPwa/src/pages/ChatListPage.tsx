import { Loader2, MessageCircle, Plus, Search } from 'lucide-react'
import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosChat } from '@/providers/PosChatProvider'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'

function fmtAddr(a: string) {
	if (!a || a.length < 10) return a
	return `${a.slice(0, 6)}…${a.slice(-4)}`
}

function fmtListTime(ts?: number) {
	if (!ts) return ''
	const d = new Date(ts)
	if (!Number.isFinite(d.getTime())) return ''
	const now = new Date()
	const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
	const startOfThatDay = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
	const diff = startOfToday - startOfThatDay
	if (diff === 0) {
		return d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
	}
	if (diff === 24 * 60 * 60 * 1000) return 'Yesterday'
	return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function threadTitle(tag?: string, name?: string, address?: string) {
	const t = (tag || '').trim()
	if (t) return t.startsWith('@') ? t : `@${t}`
	if (name?.trim()) return name.trim()
	return fmtAddr(address || '')
}

export function ChatListPage() {
	const navigate = useNavigate()
	const { threads, unreadTotal, gossipReady, gossipError } = usePosChat()
	const [q, setQ] = useState('')

	const filtered = useMemo(() => {
		const needle = q.trim().toLowerCase()
		if (!needle) return threads
		return threads.filter((t) => {
			const hay = `${t.peerTag || ''} ${t.peerName || ''} ${t.peerAddress} ${t.lastText}`.toLowerCase()
			return hay.includes(needle)
		})
	}, [threads, q])

	return (
		<PosScreenShell>
			<PosScreenHeader className="border-b border-slate-100 px-4 pb-3">
				<div className="relative flex min-h-9 items-center justify-center">
					<BeamioCircularBackButton
						className="absolute left-0 top-0"
						onClick={() => navigate(POS_HOME_ROUTES.home)}
					/>
					<div className="flex items-center gap-2">
						<MessageCircle className="h-5 w-5 text-[#1562f0]" aria-hidden />
						<h1 className="text-[17px] font-bold tracking-tight text-[#0F172A]">Messages</h1>
						{unreadTotal > 0 ? (
							<span className="rounded-full bg-[#1562f0] px-2 py-0.5 text-[11px] font-semibold text-white">
								{unreadTotal > 99 ? '99+' : unreadTotal}
							</span>
						) : null}
					</div>
					<button
						type="button"
						className="absolute right-0 top-0 inline-flex h-9 w-9 items-center justify-center rounded-full bg-[#1562f0] text-white shadow-sm active:scale-[0.96]"
						aria-label="New message"
						onClick={() => navigate(POS_HOME_ROUTES.chatCompose)}
					>
						<Plus className="h-5 w-5" strokeWidth={2.25} />
					</button>
				</div>
				<div className="relative mt-3">
					<Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
					<input
						type="search"
						value={q}
						onChange={(e) => setQ(e.target.value)}
						placeholder="Search"
						className="w-full rounded-full border border-slate-200 bg-slate-50 py-2.5 pl-9 pr-4 text-sm text-slate-800 outline-none focus:border-[#1562f0]/40 focus:ring-2 focus:ring-[#1562f0]/15"
						autoComplete="off"
					/>
				</div>
				{!gossipReady ? (
					<p className="mt-2 flex items-center gap-1.5 text-xs text-slate-500">
						{gossipError ? (
							<span className="text-amber-600">{gossipError}</span>
						) : (
							<>
								<Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden />
								Connecting to CoNET chat…
							</>
						)}
					</p>
				) : null}
			</PosScreenHeader>

			<PosScreenMain className="overflow-y-auto">
				{filtered.length === 0 ? (
					<div className="flex flex-1 flex-col items-center justify-center px-8 py-16 text-center">
						<MessageCircle className="mb-3 h-10 w-10 text-slate-300" aria-hidden />
						<p className="text-base font-semibold text-slate-700">No conversations yet</p>
						<p className="mt-1 text-sm text-slate-500">
							Start a message with a merchant or staff @BeamioTag.
						</p>
						<button
							type="button"
							className="mt-5 rounded-full bg-[#1562f0] px-5 py-2.5 text-sm font-semibold text-white"
							onClick={() => navigate(POS_HOME_ROUTES.chatCompose)}
						>
							New message
						</button>
					</div>
				) : (
					<ul className="divide-y divide-slate-100">
						{filtered.map((t) => {
							const unread = Math.max(0, t.unreadCount || 0)
							return (
								<li key={t.peerAddress.toLowerCase()}>
									<button
										type="button"
										className="flex w-full items-center gap-3 px-4 py-3.5 text-left active:bg-slate-50"
										onClick={() =>
											navigate(POS_HOME_ROUTES.chatThread(t.peerAddress))
										}
									>
										<div
											className={`flex h-12 w-12 shrink-0 items-center justify-center rounded-full text-sm font-bold text-white ${
												unread > 0 ? 'bg-[#1562f0]' : 'bg-slate-300'
											}`}
										>
											{(t.peerTag || t.peerName || t.peerAddress).slice(0, 1).toUpperCase()}
										</div>
										<div className="min-w-0 flex-1">
											<div className="flex items-center justify-between gap-2">
												<p
													className={`truncate text-[15px] ${
														unread > 0
															? 'font-bold text-slate-900'
															: 'font-semibold text-slate-800'
													}`}
												>
													{threadTitle(t.peerTag, t.peerName, t.peerAddress)}
												</p>
												<span className="shrink-0 text-[11px] text-slate-400">
													{fmtListTime(t.lastAt)}
												</span>
											</div>
											<div className="mt-0.5 flex items-center justify-between gap-2">
												<p
													className={`truncate text-sm ${
														unread > 0 ? 'font-medium text-slate-600' : 'text-slate-500'
													}`}
												>
													{t.lastText || 'No messages'}
												</p>
												{unread > 0 ? (
													<span className="shrink-0 rounded-full bg-[#1562f0] px-1.5 py-0.5 text-[10px] font-bold text-white">
														{unread > 99 ? '99+' : unread}
													</span>
												) : null}
											</div>
										</div>
									</button>
								</li>
							)
						})}
					</ul>
				)}
			</PosScreenMain>
		</PosScreenShell>
	)
}
