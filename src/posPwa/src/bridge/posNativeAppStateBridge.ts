/**
 * PWA → Native app state (icon badge, background chat notify).
 * Mirrors SilentPassUI `cashTreesNativeAppStateBridge` + BeamioPOS postMessage fallback.
 */

type CashTreesHost = 'ios' | 'android' | null

function detectCashTreesHost(): CashTreesHost {
	const w = window as Window & {
		CashTreesIOS?: { getNfcStatus?: () => string; publishAppState?: (s: unknown) => void }
		CashTreesAndroid?: { getNfcStatus?: () => string; publishAppState?: (s: string) => void }
	}
	if (typeof w.CashTreesIOS?.getNfcStatus === 'function') return 'ios'
	if (typeof w.CashTreesAndroid?.getNfcStatus === 'function') return 'android'
	return null
}

function clampBadgeCount(raw: number): number {
	if (!Number.isFinite(raw)) return 0
	return Math.max(0, Math.min(999, Math.floor(raw)))
}

export type PosNativeAppState = {
	footerBadges?: { chat?: number }
	appIconBadge?: number
	backgroundChatNotify?: { title?: string; body?: string; present?: boolean }
}

function postBeamioPosAction(action: string, payload: Record<string, unknown>): boolean {
	const body = { action, ...payload }
	const bridge = window.BeamioPOS as
		| {
				postMessage?: (b: unknown) => void
				publishAppState?: (s: unknown) => void
				notifyBackgroundChat?: (p: unknown) => void
		  }
		| undefined
	if (action === 'publishAppState' && typeof bridge?.publishAppState === 'function') {
		try {
			bridge.publishAppState(payload.state ?? payload)
			return true
		} catch {
			/* fall through */
		}
	}
	if (action === 'notifyBackgroundChat' && typeof bridge?.notifyBackgroundChat === 'function') {
		try {
			bridge.notifyBackgroundChat(payload)
			return true
		} catch {
			/* fall through */
		}
	}
	if (typeof bridge?.postMessage === 'function') {
		try {
			bridge.postMessage(body)
			return true
		} catch {
			/* fall through */
		}
	}
	const wk = window.webkit?.messageHandlers?.BeamioPOS
	if (wk?.postMessage) {
		try {
			wk.postMessage(body)
			return true
		} catch {
			return false
		}
	}
	return false
}

export function publishPosNativeAppState(state: PosNativeAppState): boolean {
	const appIconBadge =
		state.appIconBadge != null
			? clampBadgeCount(state.appIconBadge)
			: state.footerBadges?.chat != null
				? clampBadgeCount(state.footerBadges.chat)
				: undefined
	const normalized: PosNativeAppState = {
		...(state.footerBadges
			? {
					footerBadges: {
						...(state.footerBadges.chat != null
							? { chat: clampBadgeCount(state.footerBadges.chat) }
							: {}),
					},
				}
			: {}),
		...(appIconBadge != null ? { appIconBadge } : {}),
		...(state.backgroundChatNotify ? { backgroundChatNotify: state.backgroundChatNotify } : {}),
	}

	const host = detectCashTreesHost()
	const w = window as Window & {
		CashTreesIOS?: { publishAppState?: (s: unknown) => void }
		CashTreesAndroid?: { publishAppState?: (json: string) => void }
	}

	if (host === 'ios' && typeof w.CashTreesIOS?.publishAppState === 'function') {
		try {
			w.CashTreesIOS.publishAppState(normalized)
			return true
		} catch {
			/* fall through */
		}
	}
	if (host === 'android' && typeof w.CashTreesAndroid?.publishAppState === 'function') {
		try {
			w.CashTreesAndroid.publishAppState(
				JSON.stringify({ action: 'publishAppState', state: normalized }),
			)
			return true
		} catch {
			/* fall through */
		}
	}

	return postBeamioPosAction('publishAppState', { state: normalized })
}

export function syncPosChatAppIconBadge(chatCount: number): boolean {
	const n = clampBadgeCount(chatCount)
	return publishPosNativeAppState({
		footerBadges: { chat: n },
		appIconBadge: n,
	})
}

function chatNotifyBody(badge: number): string {
	if (badge <= 0) return 'New message'
	if (badge === 1) return '1 new message'
	return `${badge} new messages`
}

/** Local system notification + icon badge while shell is backgrounded. */
export function notifyPosBackgroundChat(chatCount: number): boolean {
	const badge = clampBadgeCount(chatCount)
	const body = chatNotifyBody(badge)
	const host = detectCashTreesHost()
	const w = window as Window & {
		CashTreesIOS?: { notifyBackgroundChat?: (p: Record<string, unknown>) => void }
		CashTreesAndroid?: { notifyBackgroundChat?: (json: string) => void }
	}

	if (host === 'ios' && typeof w.CashTreesIOS?.notifyBackgroundChat === 'function') {
		try {
			w.CashTreesIOS.notifyBackgroundChat({ badge, title: 'Beamio POS', body })
			return true
		} catch {
			/* fall through */
		}
	}
	if (host === 'android' && typeof w.CashTreesAndroid?.notifyBackgroundChat === 'function') {
		try {
			w.CashTreesAndroid.notifyBackgroundChat(
				JSON.stringify({ badge, title: 'Beamio POS', body }),
			)
			return true
		} catch {
			/* fall through */
		}
	}

	if (
		postBeamioPosAction('notifyBackgroundChat', {
			badge,
			appIconBadge: badge,
			title: 'Beamio POS',
			body,
		})
	) {
		return true
	}

	return publishPosNativeAppState({
		footerBadges: { chat: badge },
		appIconBadge: badge,
		backgroundChatNotify: { title: 'Beamio POS', body, present: true },
	})
}

export function isPosAppBackgrounded(): boolean {
	if (typeof document === 'undefined') return false
	return document.visibilityState === 'hidden'
}
