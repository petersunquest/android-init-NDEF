/**
 * POS PWA must **not** register a Service Worker for updates.
 * Terminal updates use Embedded OTA (`update.json` + `BeamioPOS-*.zip`).
 *
 * Call at boot (and from early inline script in `index.html`) to clear leftovers
 * so an old SW cannot keep requesting `/sw.js` or serve stale assets.
 *
 * Note: do **not** await `navigator.serviceWorker.ready` — it hangs until a SW
 * activates, which never happens on a clean POS install.
 */

export async function unregisterPosServiceWorkers(): Promise<void> {
	if (typeof window === 'undefined' || !('serviceWorker' in navigator)) return

	try {
		const regs = await navigator.serviceWorker.getRegistrations()
		await Promise.all(
			regs.map(async (reg) => {
				try {
					await reg.unregister()
				} catch {
					/* ignore single-reg failures */
				}
			}),
		)
	} catch {
		/* ignore */
	}

	if (typeof caches === 'undefined' || !caches?.keys) return
	try {
		const keys = await caches.keys()
		await Promise.all(
			keys.map(async (key) => {
				try {
					await caches.delete(key)
				} catch {
					/* ignore */
				}
			}),
		)
	} catch {
		/* ignore */
	}
}
