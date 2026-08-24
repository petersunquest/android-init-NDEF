import { useEffect, useState } from 'react'
import { searchUsers } from '@/api/beamioApi'
import type { TerminalProfile } from '@/types/pos'
import { normalizeBeamioTagInput } from '@/utils/beamioTagRules'

/** Align with consumer global search typeahead; POS chat uses ≥3 chars per product request. */
export const BEAMIO_TAG_SEARCH_MIN_CHARS = 3
const SEARCH_DEBOUNCE_MS = 280

/**
 * Remote BeamioTag search for chat / compose typeahead.
 * Trusted-empty clears hits; untrusted failure keeps previous hits.
 */
export function useBeamioTagSearch(
	query: string,
	opts?: { enabled?: boolean; excludeAddress?: string | null },
): { hits: TerminalProfile[]; searching: boolean; canSearch: boolean } {
	const enabled = opts?.enabled !== false
	const exclude = (opts?.excludeAddress || '').trim().toLowerCase()
	const needle = normalizeBeamioTagInput(query)
	const canSearch = enabled && needle.length >= BEAMIO_TAG_SEARCH_MIN_CHARS

	const [hits, setHits] = useState<TerminalProfile[]>([])
	const [searching, setSearching] = useState(false)

	useEffect(() => {
		if (!canSearch) {
			setHits([])
			setSearching(false)
			return
		}
		let cancelled = false
		const timer = window.setTimeout(() => {
			void (async () => {
				setSearching(true)
				try {
					const remote = await searchUsers(needle)
					if (cancelled) return
					if (remote === null) {
						/* untrusted — keep previous hits */
						return
					}
					const filtered = exclude
						? remote.filter((r) => (r.address || '').trim().toLowerCase() !== exclude)
						: remote
					setHits(filtered)
				} finally {
					if (!cancelled) setSearching(false)
				}
			})()
		}, SEARCH_DEBOUNCE_MS)
		return () => {
			cancelled = true
			window.clearTimeout(timer)
		}
	}, [canSearch, needle, exclude])

	return { hits, searching, canSearch }
}
