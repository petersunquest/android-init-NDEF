import { normalizeEoaLower40 } from '@/conet/crypto'

export type PosChatPartition = {
	terminalEoa: string
	upperAdminEoa: string
}

export function normalizePosChatPartition(
	terminalEoa: string | undefined,
	upperAdminEoa: string | undefined,
): PosChatPartition | null {
	const terminal = terminalEoa ? normalizeEoaLower40(terminalEoa) : null
	const upper = upperAdminEoa ? normalizeEoaLower40(upperAdminEoa) : null
	if (!terminal || !upper) return null
	return { terminalEoa: terminal, upperAdminEoa: upper }
}

export function posChatPartitionKey(partition: PosChatPartition): string {
	return `terminal:${partition.terminalEoa}:upperAdmin:${partition.upperAdminEoa}`
}
