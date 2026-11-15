/**
 * Read-only GET/eth_call helper with a hard timeout.
 *
 * Boot and home refresh await these calls. Without a ceiling, a hung backend
 * keeps `isBootLoading` true forever and the POS shows only the boot splash
 * (solid #000414 surface, i.e. a black screen). Payment / write POST calls
 * must NOT use this helper: aborting them mid-flight could double-submit.
 */
export const POS_READ_TIMEOUT_MS = 10_000

/** Thrown when a backend read fails (network, timeout, non-2xx). Distinct from "no record". */
export class PosBackendUnavailableError extends Error {
	constructor(message: string) {
		super(message)
		this.name = 'PosBackendUnavailableError'
	}
}

/**
 * One timer covers the whole request: headers AND body. The body is read inside the
 * timer and returned as a fresh Response, so callers' res.json() cannot hang past the limit.
 */
export async function posReadFetch(input: string, init?: RequestInit): Promise<Response> {
	const ctrl = new AbortController()
	const timer = setTimeout(() => ctrl.abort(), POS_READ_TIMEOUT_MS)
	try {
		const res = await fetch(input, { ...init, signal: ctrl.signal })
		/* Null-body statuses cannot carry a body: return the original response untouched. */
		if (res.status === 204 || res.status === 205 || res.status === 304) return res
		const text = await res.text()
		return new Response(text, { status: res.status, statusText: res.statusText, headers: res.headers })
	} finally {
		clearTimeout(timer)
	}
}

/**
 * Hard ceiling for the boot-time home refresh. If the chain of reads does not settle
 * in time, reject so the boot gate can still resolve a phase from local cache.
 */
export const POS_BOOT_REFRESH_CEILING_MS = 15_000

export function withPosBootCeiling(p: Promise<void>, ms: number = POS_BOOT_REFRESH_CEILING_MS): Promise<void> {
	return new Promise<void>((resolve, reject) => {
		const timer = setTimeout(
			() => reject(new PosBackendUnavailableError(`boot refresh exceeded ${ms} ms`)),
			ms,
		)
		p.then(
			() => {
				clearTimeout(timer)
				resolve()
			},
			(e: unknown) => {
				clearTimeout(timer)
				reject(e)
			},
		)
	})
}
