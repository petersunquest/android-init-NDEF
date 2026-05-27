/** Port of iOS `BeamioOpenContainerQR.parseCustomerIdentity` for Check Balance QR flow. */

export interface CustomerIdentity {
	beamioTag?: string
	wallet?: string
}

const ETH_ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/

function trimBom(raw: string): string {
	let t = raw.trim()
	if (t.charCodeAt(0) === 0xfeff) t = t.slice(1).trim()
	return t
}

function isEthAddress(v: string | undefined): v is string {
	return Boolean(v && ETH_ADDRESS_RE.test(v))
}

function extractJsonObjectSubstring(raw: string): string | null {
	const s = raw.indexOf('{')
	const e = raw.lastIndexOf('}')
	if (s < 0 || e <= s) return null
	return raw.slice(s, e + 1)
}

function parseJsonObject(content: string): Record<string, unknown> | null {
	let t = trimBom(content)
	if (!t) return null
	const candidate = extractJsonObjectSubstring(t) ?? t
	try {
		const parsed: unknown = JSON.parse(candidate)
		if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
			return parsed as Record<string, unknown>
		}
		if (typeof parsed === 'string') {
			const inner = trimBom(parsed)
			const sub = extractJsonObjectSubstring(inner) ?? inner
			const again: unknown = JSON.parse(sub)
			if (again && typeof again === 'object' && !Array.isArray(again)) {
				return again as Record<string, unknown>
			}
		}
	} catch {
		return null
	}
	return null
}

function optString(v: unknown): string {
	if (v == null) return ''
	if (typeof v === 'string') return v
	if (typeof v === 'number' && Number.isFinite(v)) return String(v)
	return String(v)
}

function customerLinkUrl(raw: string): URL | null {
	const trimmed = trimBom(raw)
	try {
		const direct = new URL(trimmed)
		if (direct.protocol === 'http:' || direct.protocol === 'https:') return direct
	} catch {
		/* fall through */
	}
	const m = trimmed.match(/https?:\/\/[^\s"'<>]+/i)
	if (!m) return null
	try {
		return new URL(m[0])
	} catch {
		return null
	}
}

function parseBeamioTab(url: URL): string | undefined {
	const v = url.searchParams.get('beamio')?.trim()
	return v || undefined
}

function parseBeamioWallet(url: URL): string | undefined {
	const v = url.searchParams.get('wallet')?.trim()
	return isEthAddress(v) ? v : undefined
}

function parseOpenContainerPayload(content: string): Record<string, unknown> | null {
	let root = parseJsonObject(content)
	if (!root) return null
	const inner = root.openContainerPayload
	if (inner && typeof inner === 'object' && !Array.isArray(inner)) {
		root = inner as Record<string, unknown>
	}
	const account = optString(root.account).trim()
	const signature = optString(root.signature).trim()
	if (!account || !signature) return null
	return root
}

export function parseCustomerIdentity(text: string): CustomerIdentity | null {
	const trimmed = trimBom(text)
	if (!trimmed) return null

	const link = customerLinkUrl(trimmed)
	if (link) {
		const beamioTag = parseBeamioTab(link)
		const wallet = parseBeamioWallet(link)
		if (beamioTag || wallet) {
			return { beamioTag, wallet }
		}
	}

	const payload = parseOpenContainerPayload(trimmed)
	if (!payload) return null
	const account = optString(payload.account).trim()
	if (!isEthAddress(account)) return null
	return { wallet: account }
}

export function customerIdentityHasTarget(id: CustomerIdentity): boolean {
	return Boolean(id.beamioTag?.trim() || isEthAddress(id.wallet))
}
