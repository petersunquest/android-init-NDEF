import { searchUsers } from '@/api/beamioApi'
import { ensureRegisteredForSenderGossip } from '@/conet/chatRouteRegister'
import { sendTerminalPermissionRequest } from '@/conet/gossipSend'
import { normalizeBeamioTagInput } from '@/utils/beamioTagRules'

export type SendPosTerminalPermissionResult =
	| { ok: true }
	| { ok: false; error: string }

/**
 * Full POS workspace approval flow over CoNET decentralized chat:
 * 1) resolve parent @BeamioTag → recipient EOA (`search-users`, not card-owner filter)
 * 2) register sender PGP on AddressPGP if needed
 * 3) assemble `beamio_pos_terminal_permission_v1` + encrypt + gossip POST
 */
export async function sendPosTerminalPermissionRequest(params: {
	walletPrivateKeyHex: string
	childEoa: string
	childBeamioTag: string
	parentBeamioTag: string
	/** Optional trusted parent EOA from Welcome profile selection. */
	parentEoaHint?: string | null
}): Promise<SendPosTerminalPermissionResult> {
	const parentTag = normalizeBeamioTagInput(params.parentBeamioTag)
	if (!parentTag) {
		return { ok: false, error: 'No workspace parent is set.' }
	}

	let recipientEoa = params.parentEoaHint?.trim() ?? ''
	if (!recipientEoa) {
		const rows = await searchUsers(parentTag)
		recipientEoa = rows?.[0]?.address?.trim() ?? ''
	}
	if (!recipientEoa) {
		return { ok: false, error: 'Could not find the parent workspace on Beamio.' }
	}

	const chatReady = await ensureRegisteredForSenderGossip(params.walletPrivateKeyHex)
	if (!chatReady) {
		return {
			ok: false,
			error: 'Could not register CoNET chat keys for this device. Check the network and try again.',
		}
	}

	const sent = await sendTerminalPermissionRequest({
		recipientEoa,
		childEoa: params.childEoa,
		childBeamioTag: params.childBeamioTag,
		parentBeamioTag: parentTag,
		walletPrivateKeyHex: params.walletPrivateKeyHex,
	})
	if (!sent) {
		return {
			ok: false,
			error: 'Could not send the CoNET permission request. Check the network and try again.',
		}
	}
	return { ok: true }
}

export function permissionAutoSentCacheKey(walletLower: string): string {
	return `pos.conet.permissionAutoSent.${walletLower}`
}

export function loadPermissionAutoSent(walletLower: string): boolean {
	try {
		return localStorage.getItem(permissionAutoSentCacheKey(walletLower)) === '1'
	} catch {
		return false
	}
}

export function savePermissionAutoSent(walletLower: string): void {
	try {
		localStorage.setItem(permissionAutoSentCacheKey(walletLower), '1')
	} catch {
		/* ignore */
	}
}
