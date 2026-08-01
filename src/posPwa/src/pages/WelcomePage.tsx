import { IpfsImg } from '@/components/IpfsImg'
import { ChevronRight, Search, Store, Terminal, X } from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { searchUsersByCardOwnerOrAdmin } from '@/api/beamioApi'
import { BeamioCapsule } from '@/components/BeamioCapsule'
import { PosScreenFooter, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { TERMINAL_HERO_IMAGE_URL } from '@/constants'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { TerminalProfile } from '@/types/pos'
import { normalizeBeamioTagInput } from '@/utils/beamioTagRules'

function WelcomeSearchResultRow({
	profile,
	onSelect,
}: {
	profile: TerminalProfile
	onSelect: () => void
}) {
	return (
		<div
			role="button"
			tabIndex={0}
			className="flex w-full cursor-pointer items-center gap-2 px-3 py-2.5 text-left hover:bg-slate-50"
			onClick={onSelect}
			onKeyDown={(e) => {
				if (e.key === 'Enter' || e.key === ' ') {
					e.preventDefault()
					onSelect()
				}
			}}
		>
			<BeamioCapsule
				profile={profile}
				fallbackAddress={profile.address}
				address={profile.address}
				showAddressCapsule
				tone="onLight"
				className="min-w-0 flex-1 rounded-full border border-mkt-outlineVariant/30 bg-white py-1 pl-1 pr-3"
			/>
			<ChevronRight className="h-4 w-4 shrink-0 text-mkt-outlineVariant" aria-hidden />
		</div>
	)
}

export function WelcomePage() {
	const navigate = useNavigate()
	const { setParentBeamioTag, setParentProfile } = usePosSession()
	const [tagQuery, setTagQuery] = useState('')
	const [results, setResults] = useState<TerminalProfile[]>([])
	const [loading, setLoading] = useState(false)
	const [selected, setSelected] = useState<TerminalProfile | null>(null)
	const requestId = useRef(0)

	const keyword = useMemo(
		() => normalizeBeamioTagInput(tagQuery).toLowerCase(),
		[tagQuery],
	)

	useEffect(() => {
		if (selected) return
		if (keyword.length < 2) {
			setResults([])
			return
		}
		const id = ++requestId.current
		const timer = window.setTimeout(async () => {
			setLoading(true)
			const rows = await searchUsersByCardOwnerOrAdmin(keyword)
			if (id !== requestId.current) return
			setResults(rows ?? [])
			setLoading(false)
		}, 350)
		return () => window.clearTimeout(timer)
	}, [keyword, selected])

	function onNextPhase() {
		if (!selected) return
		const handle = normalizeBeamioTagInput(
			selected.accountName ?? selected.username ?? keyword,
		)
		setParentProfile(selected)
		setParentBeamioTag(handle)
		navigate('/onboarding')
	}

	return (
		<PosScreenShell bg="bg-mkt-bg">
			<PosScreenMain className="mx-auto w-full max-w-xl">
				<div className="flex min-h-0 flex-1 flex-col overflow-hidden px-6 pt-[max(1rem,env(safe-area-inset-top))]">
					<div className="relative mb-4 shrink-0 overflow-hidden rounded-[14px] shadow-lg max-h-[38vh] min-h-[9rem]">
						<div className="absolute inset-0 bg-gradient-to-br from-mkt-surfaceLow to-brand-blue/15" />
						<IpfsImg
							src={TERMINAL_HERO_IMAGE_URL}
							alt=""
							className="relative h-full min-h-[9rem] w-full object-cover opacity-90 mix-blend-overlay"
						/>
						<div className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-mkt-bg via-mkt-bg/40 to-transparent p-4">
							<div className="flex items-center gap-3.5">
								<div className="flex h-12 w-12 items-center justify-center rounded-full bg-brand-blue text-white">
									<Terminal className="h-6 w-6" aria-hidden />
								</div>
								<div>
									<p className="text-sm font-bold">SoftPOS Native</p>
									<p className="text-xs text-mkt-onSurfaceVariant">Terminal Setup</p>
								</div>
							</div>
						</div>
					</div>

					<div className="min-h-0 flex-1 overflow-hidden">
						<h1 className="text-2xl font-black leading-tight tracking-tight sm:text-[2rem]">
							Link Terminal to{' '}
							<span className="text-mkt-primary">Workspace</span>
						</h1>
						<p className="mt-2 text-sm leading-relaxed text-mkt-onSurfaceVariant sm:text-[15px]">
							Enter your business{' '}
							<span className="font-semibold text-mkt-onSurface">@BeamioTag</span> to authorize
							this device.
						</p>

						<div className="mt-4">
							{!selected ? (
								<div className="relative">
									<div className="flex items-center gap-2 rounded-2xl border border-mkt-outlineVariant/60 bg-white px-4 py-3 shadow-sm">
										<Search className="h-5 w-5 shrink-0 text-mkt-onSurfaceVariant" aria-hidden />
										<input
											value={tagQuery}
											onChange={(e) => setTagQuery(e.target.value.replace(/^@+/, ''))}
											placeholder="Search @BeamioTag"
											className="w-full min-w-0 bg-transparent text-base outline-none placeholder:text-mkt-onSurfaceVariant/70"
											autoComplete="off"
											inputMode="text"
										/>
										{loading ? (
											<span className="h-4 w-4 animate-spin rounded-full border-2 border-mkt-primary border-t-transparent" />
										) : null}
									</div>
									{results.length > 0 && keyword.length >= 2 ? (
										<ul className="absolute z-20 mt-2 max-h-40 w-full overflow-y-auto rounded-2xl border border-slate-200 bg-white py-1 shadow-xl">
											{results.map((row) => {
												const key = `${row.address ?? ''}-${row.accountName ?? row.username ?? ''}`
												return (
													<li key={key}>
														<WelcomeSearchResultRow
															profile={row}
															onSelect={() => {
																setSelected(row)
																setResults([])
															}}
														/>
													</li>
												)
											})}
										</ul>
									) : null}
								</div>
							) : (
								<div className="rounded-2xl border border-brand-blue/25 bg-white p-4 shadow-sm">
									<div className="flex items-start justify-between gap-3">
										<BeamioCapsule
											profile={selected}
											fallbackAddress={selected.address}
											address={selected.address}
											showAddressCapsule
											tone="onLight"
											className="min-w-0 flex-1 rounded-full border border-mkt-outlineVariant/30 bg-white py-1 pl-1 pr-3"
										/>
										<button
											type="button"
											className="rounded-full p-2 text-mkt-onSurfaceVariant hover:bg-slate-100"
											onClick={() => setSelected(null)}
											aria-label="Clear selection"
										>
											<X className="h-5 w-5" />
										</button>
									</div>
								</div>
							)}
						</div>

						<div className="mt-4 rounded-2xl border border-mkt-outlineVariant/50 bg-white p-4">
							<div className="flex items-start gap-3">
								<div className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-mkt-surfaceLow">
									<Store className="h-5 w-5 text-mkt-primary" aria-hidden />
								</div>
								<div className="min-w-0">
									<p className="text-sm font-semibold">
										{selected ? 'Workspace selected' : 'No workspace selected'}
									</p>
									<p className="mt-1 text-sm text-mkt-onSurfaceVariant">
										{selected
											? 'Continue to create or restore your terminal wallet.'
											: 'Search and select a merchant workspace to continue.'}
									</p>
								</div>
							</div>
						</div>
					</div>
				</div>
			</PosScreenMain>

			<PosScreenFooter>
				<button
					type="button"
					disabled={!selected}
					onClick={onNextPhase}
					className="flex w-full items-center justify-center gap-2 rounded-2xl bg-brand-blue py-4 text-base font-bold text-white disabled:cursor-not-allowed disabled:opacity-40"
				>
					Next Phase
					<ChevronRight className="h-5 w-5" aria-hidden />
				</button>
			</PosScreenFooter>
		</PosScreenShell>
	)
}
