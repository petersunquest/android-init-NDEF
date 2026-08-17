import { fetchCoNETGossipNodes } from '@/conet/guardianNodes'
import { normalizePrivateKeyHex } from '@/conet/crypto'
import {
	startWorkerGossipListen,
	stopWorkerGossip,
} from '@/chat/posChatWorkerBridge'
import type { NodeInfo } from '@/vendor/beamio-chat-sdk/types'

let currentAbort: AbortController | null = null

export function stopPosChatGossipListen(): void {
	if (currentAbort) {
		try {
			currentAbort.abort('stop')
		} catch {
			/* ignore */
		}
		currentAbort = null
	}
	stopWorkerGossip()
}

export async function startPosChatGossipListen(params: {
	routerArmoredPublicKey: string
	walletPrivateKeyHex: string
	pgpPrivateKeyArmored: string
	pgpPublicKeyArmored: string
	onLine: (line: string) => void
}): Promise<boolean> {
	stopPosChatGossipListen()
	const pk = normalizePrivateKeyHex(params.walletPrivateKeyHex)
	if (!pk || !params.routerArmoredPublicKey?.trim() || !params.pgpPrivateKeyArmored?.trim()) {
		return false
	}

	const nodes = await fetchCoNETGossipNodes()
	if (!nodes.length) {
		console.warn('[POS Chat] no Guardian nodes')
		return false
	}

	const myController = new AbortController()
	currentAbort = myController
	const started = await startWorkerGossipListen({
		ownRouteArmoredPublicKey: params.routerArmoredPublicKey,
		privateKeyHex: pk,
		pgpPrivateKeyArmored: params.pgpPrivateKeyArmored,
		pgpPublicKeyArmored: params.pgpPublicKeyArmored,
		nodes: nodes as unknown as NodeInfo[],
		rootSignal: myController.signal,
		onLine: params.onLine,
		onActivity: () => {
			/* worker status already logs; keep signature for host parity */
		},
		onLog: (level, message) => {
			if (level === 'error') console.warn('[POS Chat]', message)
			else console.info('[POS Chat]', message)
		},
	})
	if (!started) {
		if (currentAbort === myController) currentAbort = null
		return false
	}
	return true
}
