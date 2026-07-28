/** Beamio tag input rules — align Android `BeamioTagRules`. */
const ALLOWED = /^[a-zA-Z0-9_.]{3,20}$/

export function normalizeBeamioTagInput(raw: string): string {
	let s = raw.trim()
	while (s.startsWith('@')) s = s.slice(1)
	return s
}

export function isValidBeamioTag(raw: string): boolean {
	const n = normalizeBeamioTagInput(raw)
	return ALLOWED.test(n)
}

export function localValidateBeamioTag(raw: string): { ok: boolean; value: string; message: string } {
	const value = normalizeBeamioTagInput(raw)
	if (!value) return { ok: false, value, message: 'Please enter a business handle' }
	if (!ALLOWED.test(value)) {
		return { ok: false, value, message: 'Use 3–20 letters, numbers, dots, or underscores' }
	}
	return { ok: true, value, message: '' }
}

/**
 * Exact @BeamioTag match for gossip encryption targets.
 * Never use search-users `results[0]` alone (e.g. CoNET vs CONET).
 */
export function pickExactBeamioTagProfile<
	T extends { username?: string; accountName?: string; address?: string },
>(
	rows: T[] | null | undefined,
	rawTag: string,
	addressHint?: string | null,
): T | null {
	if (!rows?.length) return null
	const want = normalizeBeamioTagInput(rawTag)
	if (!want) return null
	const hint = addressHint?.trim().toLowerCase() ?? ''

	const exactCase = rows.filter((r) => {
		const u = (r.username ?? '').trim()
		const a = (r.accountName ?? '').trim()
		return u === want || a === want
	})
	if (exactCase.length === 1) return exactCase[0]
	if (exactCase.length > 1 && hint) {
		const byAddr = exactCase.find((r) => (r.address ?? '').trim().toLowerCase() === hint)
		if (byAddr) return byAddr
	}
	if (exactCase.length > 1) return null

	const wantLower = want.toLowerCase()
	const caseInsensitive = rows.filter((r) => {
		const u = (r.username ?? '').trim().toLowerCase()
		const a = (r.accountName ?? '').trim().toLowerCase()
		return u === wantLower || a === wantLower
	})
	if (caseInsensitive.length === 1) return caseInsensitive[0]
	if (caseInsensitive.length > 1 && hint) {
		const byAddr = caseInsensitive.find((r) => (r.address ?? '').trim().toLowerCase() === hint)
		if (byAddr) return byAddr
	}
	return null
}

export function passwordRules(password: string): {
	len8: boolean
	mixed: boolean
	numbers: boolean
	all: boolean
} {
	const len8 = password.length >= 8
	const mixed =
		/[a-z]/.test(password) && /[A-Z]/.test(password)
	const numbers = /[0-9]/.test(password)
	return { len8, mixed, numbers, all: len8 && mixed && numbers }
}
