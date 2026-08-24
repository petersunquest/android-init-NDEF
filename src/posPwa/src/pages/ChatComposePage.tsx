import { Loader2 } from 'lucide-react'
import { useCallback, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { isAddress } from 'ethers'
import { searchUsers } from '@/api/beamioApi'
import { BeamioCapsule } from '@/components/BeamioCapsule'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenFooter, PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import {
	BEAMIO_TAG_SEARCH_MIN_CHARS,
	useBeamioTagSearch,
} from '@/hooks/useBeamioTagSearch'
import { usePosChat } from '@/providers/PosChatProvider'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { TerminalProfile } from '@/types/pos'
import {
	localValidateBeamioTag,
	normalizeBeamioTagInput,
	pickExactBeamioTagProfile,
} from '@/utils/beamioTagRules'
import { profileBeamioTag, profileDisplayName } from '@/utils/display'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'

export function ChatComposePage() {
	const navigate = useNavigate()
	const { openOrCreateThread } = usePosChat()
	const { walletAddress } = usePosSession()
	const [input, setInput] = useState('')
	const [busy, setBusy] = useState(false)
	const [error, setError] = useState<string | null>(null)

	const { hits, searching, canSearch } = useBeamioTagSearch(input, {
		excludeAddress: walletAddress,
	})

	const openHit = useCallback(
		(hit: TerminalProfile) => {
			const addr = (hit.address || '').trim()
			if (!addr || !isAddress(addr)) {
				setError('Invalid user address')
				return
			}
			const tag = profileBeamioTag(hit)
			const name = profileDisplayName(hit)
			openOrCreateThread(addr, {
				peerTag: tag || undefined,
				peerName: name || undefined,
			})
			navigate(POS_HOME_ROUTES.chatThread(addr), { replace: true })
		},
		[navigate, openOrCreateThread],
	)

	const onContinue = async () => {
		if (busy) return
		setError(null)
		const raw = input.trim()
		if (!raw) {
			setError('Enter an @BeamioTag or wallet address')
			return
		}

		setBusy(true)
		try {
			if (isAddress(raw)) {
				openOrCreateThread(raw)
				navigate(POS_HOME_ROUTES.chatThread(raw), { replace: true })
				return
			}

			const tagCheck = localValidateBeamioTag(raw)
			if (!tagCheck.ok) {
				setError(tagCheck.message || 'Invalid @BeamioTag')
				return
			}
			const tag = normalizeBeamioTagInput(tagCheck.value)
			const fromHits = pickExactBeamioTagProfile(hits, tag)
			const rows = fromHits ? [fromHits] : ((await searchUsers(tag)) ?? [])
			const exact = pickExactBeamioTagProfile(rows, tag)
			if (!exact?.address || !isAddress(exact.address)) {
				setError('No user found for that @BeamioTag')
				return
			}
			openHit(exact)
		} finally {
			setBusy(false)
		}
	}

	return (
		<PosScreenShell>
			<PosScreenHeader className="border-b border-slate-100 px-4 pb-3">
				<div className="relative flex min-h-9 items-center justify-center">
					<BeamioCircularBackButton
						className="absolute left-0 top-0"
						onClick={() => navigate(POS_HOME_ROUTES.chat)}
					/>
					<h1 className="text-[17px] font-bold tracking-tight text-[#0F172A]">New message</h1>
				</div>
			</PosScreenHeader>

			<PosScreenMain className="px-4 pt-6">
				<label htmlFor="pos-chat-to" className="text-sm font-semibold text-slate-700">
					To
				</label>
				<input
					id="pos-chat-to"
					type="text"
					value={input}
					onChange={(e) => {
						setInput(e.target.value)
						setError(null)
					}}
					placeholder="@BeamioTag or 0x…"
					autoComplete="off"
					autoCapitalize="none"
					spellCheck={false}
					enterKeyHint="done"
					tabIndex={1}
					className="mt-2 w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 text-base text-slate-800 outline-none focus:border-[#1562f0]/40 focus:ring-2 focus:ring-[#1562f0]/15"
					onKeyDown={(e) => {
						if (e.key === 'Enter') {
							e.preventDefault()
							void onContinue()
						}
					}}
				/>
				{error ? (
					<p className="mt-2 text-sm text-amber-600" role="alert">
						{error}
					</p>
				) : (
					<p className="mt-2 text-sm text-slate-500">
						Type {BEAMIO_TAG_SEARCH_MIN_CHARS}+ characters to search @BeamioTag. Messages are
						encrypted to the recipient&apos;s EOA PGP on CoNET.
					</p>
				)}

				{canSearch ? (
					<div className="mt-4">
						<div className="mb-1 flex items-center justify-between">
							<p className="text-[11px] font-bold uppercase tracking-[0.14em] text-slate-400">
								People
							</p>
							{searching ? (
								<span className="flex items-center gap-1 text-[11px] text-slate-400">
									<Loader2 className="h-3 w-3 animate-spin" aria-hidden />
									Searching…
								</span>
							) : null}
						</div>
						{hits.length > 0 ? (
							<ul className="max-h-64 space-y-1 overflow-y-auto rounded-2xl border border-slate-100 bg-white py-1">
								{hits.map((hit) => {
									const key = `${hit.address}-${profileBeamioTag(hit)}`
									return (
										<li key={key}>
											<button
												type="button"
												tabIndex={-1}
												disabled={busy}
												className="flex w-full items-center rounded-xl px-2 py-2 text-left hover:bg-slate-50 active:bg-slate-50 disabled:opacity-50"
												onClick={() => openHit(hit)}
											>
												<BeamioCapsule
													profile={hit}
													fallbackAddress={hit.address}
													address={hit.address}
													showAddressCapsule
													tone="onLight"
													className="min-w-0"
												/>
											</button>
										</li>
									)
								})}
							</ul>
						) : !searching ? (
							<p className="rounded-2xl border border-dashed border-slate-200 px-3 py-3 text-sm text-slate-400">
								No results
							</p>
						) : null}
					</div>
				) : null}
			</PosScreenMain>

			<PosScreenFooter>
				<button
					type="button"
					tabIndex={2}
					disabled={busy || !input.trim()}
					aria-busy={busy}
					onClick={() => void onContinue()}
					className="flex w-full items-center justify-center gap-2 rounded-2xl bg-[#1562f0] py-3.5 text-[15px] font-semibold text-white disabled:opacity-40"
				>
					{busy ? <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> : null}
					Continue
				</button>
			</PosScreenFooter>
		</PosScreenShell>
	)
}
