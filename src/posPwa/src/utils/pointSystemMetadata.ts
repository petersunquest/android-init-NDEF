function recordDictionary(raw: unknown): Record<string, unknown> | null {
	if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
		return raw as Record<string, unknown>
	}
	if (typeof raw === 'string') {
		try {
			const parsed = JSON.parse(raw) as unknown
			if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
				return parsed as Record<string, unknown>
			}
		} catch {
			return null
		}
	}
	return null
}

function parseMetadataBooleanLike(raw: unknown): boolean | null {
	if (typeof raw === 'boolean') return raw
	if (typeof raw === 'number') return raw !== 0
	if (typeof raw === 'string') {
		const t = raw.trim().toLowerCase()
		if (['true', '1', 'yes', 'on', 'enabled'].includes(t)) return true
		if (['false', '0', 'no', 'off', 'disabled'].includes(t)) return false
	}
	return null
}

function parseMetadataRatioE6String(raw: unknown): string | null {
	if (typeof raw === 'number' && Number.isFinite(raw) && raw >= 0) {
		return String(Math.trunc(raw))
	}
	if (typeof raw === 'string') {
		const t = raw.replace(/,/g, '').trim()
		if (t && /^\d+$/.test(t)) return t
	}
	return null
}

/**
 * Card Issuance `shareTokenMetadata.pointSystem.enabled` — aligns iOS/Android POS.
 * Legacy cards without an explicit block default to enabled.
 */
export function parsePointSystemEnabledFromMetadata(meta: Record<string, unknown>): boolean {
	const share = recordDictionary(meta.shareTokenMetadata)
	const pointSystem =
		recordDictionary(meta.pointSystem) ?? recordDictionary(share?.pointSystem)
	if (pointSystem) {
		const enabledRaw =
			pointSystem.enabled ??
			pointSystem.pointSystemEnabled ??
			pointSystem.pointsEnabled
		const parsed = parseMetadataBooleanLike(enabledRaw)
		if (parsed != null) return parsed
		const ratioRaw =
			pointSystem.chargeRewardRatioE6 ??
			pointSystem.pointRewardRatioE6 ??
			pointSystem.consumptionRewardRatioE6
		const ratioStr = parseMetadataRatioE6String(ratioRaw)
		if (ratioStr != null) {
			try {
				return BigInt(ratioStr) > 0n
			} catch {
				return Number(ratioStr) > 0
			}
		}
		return true
	}
	const flatEnabled =
		share?.pointSystemEnabled ??
		share?.pointsEnabled ??
		meta.pointSystemEnabled ??
		meta.pointsEnabled
	const flatParsed = parseMetadataBooleanLike(flatEnabled)
	return flatParsed ?? true
}
