import { programCardDisplayLine } from '@/utils/posReceiptUtils'

const GENERIC_PROGRAM_NAMES = new Set([
	'infrastructure card',
	'asset card',
	'card',
	'beamio user card',
	'beamio ccsa card',
])

/** iOS `merchantProgramMetadataDisplayName` — `getWalletAssets` `cards[].cardName` / metadata `name`. */
export function merchantProgramMetadataDisplayName(
	cardName: string | null | undefined,
): string | null {
	const line = programCardDisplayLine(cardName)
	if (!line || line === '—') return null
	if (GENERIC_PROGRAM_NAMES.has(line.toLowerCase())) return null
	return line
}

export function businessNameFromCardMetadataRoot(
	metadata: Record<string, unknown> | null | undefined,
): string | null {
	if (!metadata || typeof metadata !== 'object') return null
	const stm = metadata.shareTokenMetadata
	if (stm && typeof stm === 'object' && !Array.isArray(stm)) {
		const fromStm = merchantProgramMetadataDisplayName(
			String((stm as { name?: string }).name ?? ''),
		)
		if (fromStm) return fromStm
	}
	return merchantProgramMetadataDisplayName(
		String(metadata.name ?? metadata.title ?? ''),
	)
}
