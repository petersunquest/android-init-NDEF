/** Native receipt printer bridge — softPOS / CashTrees iOS `CashTreesIOS.printReceipt`. */

function iosBridge() {
	return window.CashTreesIOS
}

export function hasCashTreesPrintBridge(): boolean {
	return typeof iosBridge()?.printReceipt === 'function'
}

/** Native shell → AirPrint; returns false when bridge unavailable (caller may fall back to `window.print`). */
export function printPosReceipt(params: { text: string; title?: string }): boolean {
	const text = params.text.trim()
	if (!text) return false
	const title = params.title?.trim() || 'Receipt'
	const bridge = iosBridge()?.printReceipt
	if (typeof bridge !== 'function') return false
	bridge({ text, title })
	return true
}
