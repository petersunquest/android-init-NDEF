import { normalizeBeamioTagInput } from './beamioTagRules'

/** Align iOS/Android `assemblePosTerminalBeamioTag`. */
export function assemblePosTerminalBeamioTag(parentRaw: string, sequence: number): string {
	const seq = Math.min(Math.max(sequence, 0), 9999)
	const tail = `_POS_${String(seq).padStart(4, '0')}`
	let base = normalizeBeamioTagInput(parentRaw).replace(/[^a-zA-Z0-9_.]/g, '')
	if (!base) base = 'pos'
	const maxPrefix = Math.max(0, 20 - tail.length)
	if (base.length > maxPrefix) base = base.slice(0, maxPrefix)
	const combined = base + tail
	if (combined.length < 3) return `pos${tail}`
	return combined
}

export async function resolveFirstAvailablePosTerminalTag(
	parentRaw: string,
	isAvailable: (candidate: string) => Promise<boolean | null>,
): Promise<string> {
	const parent = normalizeBeamioTagInput(parentRaw)
	if (!parent) return ''

	for (let n = 1; n <= 9999; n++) {
		const candidate = assemblePosTerminalBeamioTag(parentRaw, n)
		if (!/^[a-zA-Z0-9_.]{3,20}$/.test(candidate)) continue
		const avail = await isAvailableWithRetries(candidate, isAvailable)
		if (avail === true) return candidate
		if (avail === false) continue
		return ''
	}
	return ''
}

async function isAvailableWithRetries(
	candidate: string,
	isAvailable: (candidate: string) => Promise<boolean | null>,
): Promise<boolean | null> {
	for (let attempt = 0; attempt < 3; attempt++) {
		const result = await isAvailable(candidate)
		if (result === true || result === false) return result
		if (attempt < 2) await sleep(400)
	}
	return null
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms))
}
