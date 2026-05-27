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
