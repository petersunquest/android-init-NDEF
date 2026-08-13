import { Loader2 } from 'lucide-react'
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { isAddress } from 'ethers'
import { searchUsers } from '@/api/beamioApi'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenFooter, PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosChat } from '@/providers/PosChatProvider'
import {
	localValidateBeamioTag,
	normalizeBeamioTagInput,
	pickExactBeamioTagProfile,
} from '@/utils/beamioTagRules'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'

export function ChatComposePage() {
	const navigate = useNavigate()
	const { openOrCreateThread } = usePosChat()
	const [input, setInput] = useState('')
	const [busy, setBusy] = useState(false)
	const [error, setError] = useState<string | null>(null)

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
			const rows = (await searchUsers(tag)) ?? []
			const exact = pickExactBeamioTagProfile(rows, tag)
			if (!exact?.address || !isAddress(exact.address)) {
				setError('No user found for that @BeamioTag')
				return
			}
			const name = `${exact.first_name || ''} ${String(exact.last_name || '').split('\r\n')[0] || ''}`.trim()
			openOrCreateThread(exact.address, {
				peerTag: exact.accountName || exact.username || tag,
				peerName: name || undefined,
			})
			navigate(POS_HOME_ROUTES.chatThread(exact.address), { replace: true })
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
					onChange={(e) => setInput(e.target.value)}
					placeholder="@BeamioTag or 0x…"
					autoComplete="off"
					autoCapitalize="none"
					spellCheck={false}
					enterKeyHint="done"
					tabIndex={1}
					className="mt-2 w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 text-[15px] text-slate-800 outline-none focus:border-[#1562f0]/40 focus:ring-2 focus:ring-[#1562f0]/15"
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
						Messages are encrypted to the recipient&apos;s EOA PGP on CoNET.
					</p>
				)}
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
