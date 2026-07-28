import { Check, Loader2, Plus, Search } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { searchUsers, searchUsersByCardOwnerOrAdmin } from '@/api/beamioApi'
import { BeamioCapsule } from '@/components/BeamioCapsule'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { TerminalProfile } from '@/types/pos'
import { localValidateBeamioTag, normalizeBeamioTagInput, pickExactBeamioTagProfile } from '@/utils/beamioTagRules'
import { profileBeamioTag, profileDisplayName, shortAddress } from '@/utils/display'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'

export function WorkspaceMerchantsPage() {
	const navigate = useNavigate()
	const {
		activeUpperEoa,
		workspaceBindings,
		outboundJoinPending,
		refreshWorkspaceBindings,
		switchWorkspace,
		requestJoinWorkspace,
	} = usePosSession()

	const [switchingCard, setSwitchingCard] = useState<string | null>(null)
	const [actionError, setActionError] = useState<string | null>(null)
	const [showJoin, setShowJoin] = useState(false)
	const [joinQuery, setJoinQuery] = useState('')
	const [joinHits, setJoinHits] = useState<TerminalProfile[]>([])
	const [joinSearching, setJoinSearching] = useState(false)
	const [joinSending, setJoinSending] = useState(false)
	const [selectedParent, setSelectedParent] = useState<TerminalProfile | null>(null)

	useEffect(() => {
		void refreshWorkspaceBindings()
	}, [refreshWorkspaceBindings])

	useEffect(() => {
		const q = normalizeBeamioTagInput(joinQuery)
		if (q.length < 2) {
			setJoinHits([])
			return
		}
		let cancelled = false
		const t = window.setTimeout(() => {
			void (async () => {
				setJoinSearching(true)
				try {
					const rows =
						(await searchUsersByCardOwnerOrAdmin(q)) ?? (await searchUsers(q)) ?? []
					if (!cancelled) setJoinHits(rows)
				} finally {
					if (!cancelled) setJoinSearching(false)
				}
			})()
		}, 280)
		return () => {
			cancelled = true
			window.clearTimeout(t)
		}
	}, [joinQuery])

	const onSwitch = useCallback(
		async (upperEoa: string, cardAddress: string) => {
			if (switchingCard) return
			setActionError(null)
			setSwitchingCard(cardAddress)
			try {
				const res = await switchWorkspace({ upperEoa, cardAddress })
				if (!res.ok) setActionError(res.error)
			} finally {
				setSwitchingCard(null)
			}
		},
		[switchWorkspace, switchingCard],
	)

	const onSendJoin = useCallback(async () => {
		if (joinSending) return
		const tagCheck = localValidateBeamioTag(
			selectedParent ? profileBeamioTag(selectedParent) || joinQuery : joinQuery,
		)
		if (!tagCheck.ok) {
			setActionError(tagCheck.message)
			return
		}
		let hint = selectedParent?.address?.trim() ?? ''
		if (!hint) {
			const exact = pickExactBeamioTagProfile(joinHits, tagCheck.value)
			hint = exact?.address?.trim() ?? ''
		}
		setJoinSending(true)
		setActionError(null)
		try {
			const res = await requestJoinWorkspace({
				parentTag: tagCheck.value,
				parentEoaHint: hint || null,
			})
			if (!res.ok) {
				setActionError(res.error)
				return
			}
			setShowJoin(false)
			setJoinQuery('')
			setSelectedParent(null)
			setJoinHits([])
		} finally {
			setJoinSending(false)
		}
	}, [joinSending, selectedParent, joinQuery, joinHits, requestJoinWorkspace])

	return (
		<PosScreenShell bg="bg-[#f2f2f7]">
			<PosScreenHeader>
				<div className="flex items-center gap-3 px-4 pb-2.5 pt-3">
					<BeamioCircularBackButton onClick={() => navigate(POS_HOME_ROUTES.home)} />
					<div className="min-w-0 flex-1">
						<h1 className="text-lg font-semibold text-mkt-onSurface">Workspaces</h1>
						<p className="text-[11px] text-mkt-onSurfaceVariant">
							Linked merchants &amp; join requests
						</p>
					</div>
				</div>
			</PosScreenHeader>

			<PosScreenMain className="px-4 pb-[max(1.25rem,env(safe-area-inset-bottom))] pt-2">
				{actionError ? (
					<p className="mb-3 rounded-2xl bg-amber-50 px-3 py-2 text-sm text-amber-900" role="alert">
						{actionError}
					</p>
				) : null}

				<section className="mb-6">
					<h2 className="mb-2 text-[11px] font-black uppercase tracking-[0.2em] text-slate-500">
						Linked
					</h2>
					{workspaceBindings.length === 0 ? (
						<p className="rounded-2xl bg-white px-4 py-5 text-sm text-slate-500 shadow-sm">
							No linked merchant cards yet. Ask a merchant to approve this terminal, or
							request to join below.
						</p>
					) : (
						<ul className="space-y-2">
							{workspaceBindings.map((row) => {
								const upper = row.upperEoa?.trim() ?? ''
								const isActive =
									row.isActive ||
									(activeUpperEoa &&
										upper &&
										activeUpperEoa.toLowerCase() === upper.toLowerCase())
								const profile =
									row.adminProfile ??
									({
										address: upper || row.cardAddress,
										accountName: shortAddress(upper || row.cardAddress),
									} satisfies TerminalProfile)
								const busy = switchingCard === row.cardAddress
								return (
									<li key={row.cardAddress}>
										<button
											type="button"
											disabled={Boolean(isActive) || busy || !upper}
											onClick={() => {
												if (!upper) return
												void onSwitch(upper, row.cardAddress)
											}}
											className={[
												'flex w-full items-center gap-3 rounded-2xl bg-white px-3 py-3 text-left shadow-sm',
												'transition active:scale-[0.99]',
												isActive ? 'ring-2 ring-[#1562f0]/35' : 'hover:bg-slate-50',
												'disabled:opacity-100',
											].join(' ')}
											aria-label={
												isActive
													? 'Current workspace'
													: `Switch to ${profileBeamioTag(profile) || shortAddress(upper)}`
											}
										>
											<div className="min-w-0 flex-1">
												<BeamioCapsule profile={profile} tone="onLight" />
												<p className="mt-1 truncate pl-11 text-[11px] text-slate-400">
													{shortAddress(row.cardAddress)}
												</p>
											</div>
											{busy ? (
												<Loader2 className="h-5 w-5 shrink-0 animate-spin text-[#1562f0]" />
											) : isActive ? (
												<span className="inline-flex items-center gap-1 rounded-full bg-[#1562f0]/12 px-2.5 py-1 text-[11px] font-semibold text-[#1562f0]">
													<Check className="h-3.5 w-3.5" aria-hidden />
													Current
												</span>
											) : (
												<span className="text-[12px] font-semibold text-[#1562f0]">Switch</span>
											)}
										</button>
									</li>
								)
							})}
						</ul>
					)}
				</section>

				<section className="mb-6">
					<h2 className="mb-2 text-[11px] font-black uppercase tracking-[0.2em] text-slate-500">
						Pending join
					</h2>
					{outboundJoinPending.length === 0 ? (
						<p className="rounded-2xl bg-white/70 px-4 py-4 text-sm text-slate-500">
							No outbound join requests.
						</p>
					) : (
						<ul className="space-y-2">
							{outboundJoinPending.map((p) => (
								<li
									key={`${p.parentEoa}-${p.requestedAt}`}
									className="rounded-2xl bg-white px-4 py-3 shadow-sm"
								>
									<p className="text-sm font-semibold text-slate-900">@{p.parentTag}</p>
									<p className="mt-0.5 text-[11px] text-slate-400">
										{shortAddress(p.parentEoa)} · waiting for approval
									</p>
								</li>
							))}
						</ul>
					)}
				</section>

				{showJoin ? (
					<section className="rounded-2xl bg-white p-4 shadow-sm">
						<h2 className="mb-3 text-sm font-semibold text-slate-900">Request to join another</h2>
						<label htmlFor="workspace-join-tag" className="sr-only">
							Parent @BeamioTag
						</label>
						<div className="relative">
							<Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
							<input
								id="workspace-join-tag"
								type="text"
								autoComplete="off"
								autoCorrect="off"
								autoCapitalize="none"
								spellCheck={false}
								enterKeyHint="search"
								inputMode="text"
								value={joinQuery}
								onChange={(e) => {
									setSelectedParent(null)
									setJoinQuery(e.target.value)
								}}
								placeholder="@merchant"
								/* text-base (16px): iOS will not auto-zoom on focus when font-size >= 16. */
								className="w-full rounded-xl border border-slate-200 bg-slate-50 py-2.5 pl-9 pr-3 text-base text-slate-900 outline-none focus:border-[#1562f0] focus:ring-2 focus:ring-[#1562f0]/20"
							/>
						</div>
						{joinSearching ? (
							<p className="mt-2 flex items-center gap-2 text-xs text-slate-500">
								<Loader2 className="h-3.5 w-3.5 animate-spin" /> Searching…
							</p>
						) : null}
						{joinHits.length > 0 ? (
							<ul className="mt-2 max-h-48 space-y-1 overflow-y-auto">
								{joinHits.map((hit) => {
									const tag = profileBeamioTag(hit)
									const selected =
										selectedParent?.address?.toLowerCase() === hit.address?.toLowerCase()
									return (
										<li key={`${hit.address}-${tag}`}>
											<button
												type="button"
												onClick={() => {
													setSelectedParent(hit)
													if (tag) setJoinQuery(tag)
													// Blur search field so iOS dismisses keyboard and any focus zoom.
													const el = document.getElementById(
														'workspace-join-tag',
													) as HTMLInputElement | null
													el?.blur()
												}}
												className={[
													'flex w-full items-center rounded-xl px-2 py-2 text-left',
													selected ? 'bg-[#1562f0]/10' : 'hover:bg-slate-50',
												].join(' ')}
											>
												<BeamioCapsule profile={hit} tone="onLight" className="min-w-0" />
											</button>
										</li>
									)
								})}
							</ul>
						) : null}
						{selectedParent ? (
							<p className="mt-2 text-xs text-slate-500">
								Selected{' '}
								<span className="font-semibold text-slate-800">
									{profileDisplayName(selectedParent) || `@${profileBeamioTag(selectedParent)}`}
								</span>
							</p>
						) : null}
						<div className="mt-4 flex gap-2">
							<button
								type="button"
								tabIndex={-1}
								disabled={joinSending}
								onClick={() => {
									setShowJoin(false)
									setJoinQuery('')
									setSelectedParent(null)
									setActionError(null)
								}}
								className="flex-1 rounded-xl bg-slate-100 py-2.5 text-sm font-semibold text-slate-700"
							>
								Cancel
							</button>
							<button
								type="button"
								disabled={joinSending}
								aria-busy={joinSending}
								onClick={() => void onSendJoin()}
								className="flex flex-1 items-center justify-center gap-2 rounded-xl bg-[#1562f0] py-2.5 text-sm font-semibold text-white disabled:opacity-60"
							>
								{joinSending ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
								Send request
							</button>
						</div>
					</section>
				) : (
					<button
						type="button"
						onClick={() => {
							setActionError(null)
							setShowJoin(true)
						}}
						className="flex w-full items-center justify-center gap-2 rounded-2xl bg-[#1562f0] py-3.5 text-sm font-bold text-white shadow-[0_4px_16px_rgba(21,98,240,0.28)]"
					>
						<Plus className="h-4 w-4" aria-hidden />
						Request to join another
					</button>
				)}
			</PosScreenMain>
		</PosScreenShell>
	)
}
