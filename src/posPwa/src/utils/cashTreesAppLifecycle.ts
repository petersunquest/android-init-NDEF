/**
 * Track whether the native shell / WebView is behind Home while PWA JS may still run.
 * Used for unread-while-viewing a thread. System chat push is SI mailbox only.
 * Independent copy of SilentPassUI cashTreesAppLifecycle (no cross-project import).
 */

type LifecyclePhase = 'active' | 'inactive' | 'background'

let phase: LifecyclePhase = 'active'
const listeners = new Set<(p: LifecyclePhase) => void>()

function setPhase(next: LifecyclePhase): void {
	if (phase === next) return
	phase = next
	for (const fn of listeners) {
		try {
			fn(phase)
		} catch {
			/* ignore */
		}
	}
}

function phaseFromVisibility(): LifecyclePhase {
	if (typeof document === 'undefined') return 'active'
	return document.visibilityState === 'hidden' ? 'background' : 'active'
}

function onNativeLifecycle(ev: Event): void {
	const detail = (ev as CustomEvent<{ action?: string; phase?: string }>).detail
	if (!detail || detail.action !== 'appLifecycle') return
	const p = String(detail.phase || '').toLowerCase()
	if (p === 'background' || p === 'inactive' || p === 'active') {
		setPhase(p as LifecyclePhase)
	}
}

let installed = false

/** Install once (App / PosChatProvider). Safe to call repeatedly. */
export function ensureCashTreesAppLifecycleTracking(): void {
	if (typeof window === 'undefined' || installed) return
	installed = true
	setPhase(phaseFromVisibility())
	document.addEventListener('visibilitychange', () => {
		if (document.visibilityState === 'visible') {
			setPhase('active')
		} else {
			setPhase('background')
		}
	})
	window.addEventListener('cashtreesios', onNativeLifecycle as EventListener)
	window.addEventListener('cashtreesandroid', onNativeLifecycle as EventListener)
}

export function getCashTreesAppLifecyclePhase(): LifecyclePhase {
	return phase
}

/** True when Home / app switcher has put the shell behind (or tab hidden). */
export function isCashTreesAppBackgrounded(): boolean {
	return phase === 'background' || phase === 'inactive'
}

export function subscribeCashTreesAppLifecycle(fn: (p: LifecyclePhase) => void): () => void {
	listeners.add(fn)
	return () => {
		listeners.delete(fn)
	}
}
