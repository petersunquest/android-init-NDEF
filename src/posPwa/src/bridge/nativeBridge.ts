import type { PosNativeAction } from '@/types/pos'
import {
	checkPosWalletStorage,
	createPosWalletWithIndexedDb,
	getSessionPrivateKeyHex,
	getSessionWalletAddress,
	hasSessionWallet,
	restorePosWalletWithIndexedDb,
} from '@/wallet/posWalletService'
import { hasPosWalletInIndexedDb } from '@/wallet/posWalletStorage'

export type PosNativePlatform = 'ios' | 'android' | 'web'

export interface PosNativeBridge {
	platform: PosNativePlatform
	getWalletAddress(): Promise<string | null>
	getWalletPrivateKeyHex(): Promise<string | null>
	hasStoredWallet(): Promise<boolean>
	createWallet(params: {
		accountName: string
		password: string
		parentBeamioTag: string
	}): Promise<{ ok: boolean; address?: string; error?: string; recoveryCode?: string }>
	restoreWallet(params: {
		accountName: string
		password: string
	}): Promise<{ ok: boolean; address?: string; error?: string }>
	navigateNative(action: PosNativeAction): void
	resendParentPermissionRequest(): Promise<void>
}

declare global {
	interface Window {
		BeamioPOS?: Partial<PosNativeBridge>
		webkit?: {
			messageHandlers?: {
				BeamioPOS?: { postMessage: (body: unknown) => void }
			}
		}
	}
}

const BRIDGE_EVENT = 'beamiopos'

function postToNative(type: string, payload: Record<string, unknown> = {}): void {
	const body = { type, ...payload }
	const bridgePost = (window.BeamioPOS as { postMessage?: (b: unknown) => void } | undefined)
		?.postMessage
	if (typeof bridgePost === 'function') {
		bridgePost(body)
		return
	}
	window.webkit?.messageHandlers?.BeamioPOS?.postMessage(body)
}

function detectPlatform(): PosNativePlatform {
	const bridge = window.BeamioPOS
	if (bridge?.platform === 'ios' || bridge?.platform === 'android') return bridge.platform
	if (window.webkit?.messageHandlers?.BeamioPOS) return 'ios'
	if (bridge && typeof bridge.getWalletAddress === 'function') return 'android'
	return 'web'
}

function useNativeBridge(): boolean {
	return detectPlatform() !== 'web' && Boolean(window.BeamioPOS?.createWallet)
}

export const posNativeBridge: PosNativeBridge = {
	platform: detectPlatform(),

	async getWalletAddress(): Promise<string | null> {
		if (window.BeamioPOS?.getWalletAddress) {
			return window.BeamioPOS.getWalletAddress()
		}
		if (getSessionWalletAddress()) return getSessionWalletAddress()
		await checkPosWalletStorage()
		return getSessionWalletAddress()
	},

	async getWalletPrivateKeyHex(): Promise<string | null> {
		if (window.BeamioPOS?.getWalletPrivateKeyHex) {
			return window.BeamioPOS.getWalletPrivateKeyHex()
		}
		if (getSessionPrivateKeyHex()) return getSessionPrivateKeyHex()
		await checkPosWalletStorage()
		return getSessionPrivateKeyHex()
	},

	async hasStoredWallet(): Promise<boolean> {
		if (window.BeamioPOS?.hasStoredWallet) {
			return window.BeamioPOS.hasStoredWallet()
		}
		if (hasSessionWallet()) return true
		return hasPosWalletInIndexedDb()
	},

	async createWallet(params) {
		if (useNativeBridge()) {
			return window.BeamioPOS!.createWallet!(params)
		}
		const result = await createPosWalletWithIndexedDb(params)
		if (!result.ok) return result
		return {
			ok: true,
			address: result.address,
			recoveryCode: result.recoveryCode,
		}
	},

	async restoreWallet(params) {
		if (window.BeamioPOS?.restoreWallet) {
			return window.BeamioPOS.restoreWallet(params)
		}
		return restorePosWalletWithIndexedDb(params)
	},

	navigateNative(action) {
		if (window.BeamioPOS?.navigateNative) {
			window.BeamioPOS.navigateNative(action)
			return
		}
		postToNative('navigate', { action })
		window.dispatchEvent(new CustomEvent(BRIDGE_EVENT, { detail: { type: 'navigate', action } }))
	},

	async resendParentPermissionRequest() {
		if (window.BeamioPOS?.resendParentPermissionRequest) {
			await window.BeamioPOS.resendParentPermissionRequest()
			return
		}
		postToNative('resendParentPermission')
	},
}

export function isNativePosShell(): boolean {
	return posNativeBridge.platform !== 'web'
}

export function listenNativeBridge(handler: (detail: unknown) => void): () => void {
	const fn = (e: Event) => handler((e as CustomEvent).detail)
	window.addEventListener(BRIDGE_EVENT, fn)
	return () => window.removeEventListener(BRIDGE_EVENT, fn)
}

/** Call once at app boot — SilentPassUI `init` → `checkStorage` parity. */
export async function bootstrapPosWalletFromIndexedDb(): Promise<void> {
	if (useNativeBridge()) return
	await checkPosWalletStorage()
}
