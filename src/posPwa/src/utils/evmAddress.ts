/** iOS `BeamioAPIClient.isPlausibleEvmAddress` / ContentView `readBalanceLooksLikeEvmAddress`. */
export function isPlausibleEvmAddress(raw: string | null | undefined): boolean {
	const s = (raw ?? '').trim().toLowerCase()
	if (!s.startsWith('0x') || s.length !== 42) return false
	return /^0x[0-9a-f]{40}$/.test(s)
}
