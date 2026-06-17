#!/usr/bin/env node
/**
 * CoNET publicrpc WSS bridge: WebSocket JSON-RPC -> local geth IPC.
 * Enables wss://publicrpc.conet.network/ws without restarting geth (--ws not required).
 */
import net from 'node:net';
import { WebSocketServer } from 'ws';

const GETH_IPC =
	process.env.GETH_IPC ||
	'/home/peter/ethereum-pos-mainnet/network/node-0/execution/geth.ipc';
const WS_HOST = process.env.WS_HOST || '127.0.0.1';
const WS_PORT = Number(process.env.WS_PORT || '8890');

function attachIpcToWebSocket(ws) {
	const ipc = net.connect(GETH_IPC);
	let buf = '';

	const closeBoth = () => {
		try {
			ipc.destroy();
		} catch {
			/* ignore */
		}
		try {
			ws.close();
		} catch {
			/* ignore */
		}
	};

	ipc.on('connect', () => {
		// eslint-disable-next-line no-console
		console.log('[conet-ws-bridge] ipc connected');
	});

	ipc.on('data', (chunk) => {
		buf += chunk.toString('utf8');
		let nl;
		while ((nl = buf.indexOf('\n')) >= 0) {
			const line = buf.slice(0, nl).trim();
			buf = buf.slice(nl + 1);
			if (line && ws.readyState === ws.OPEN) ws.send(line);
		}
	});

	ipc.on('error', (err) => {
		// eslint-disable-next-line no-console
		console.error('[conet-ws-bridge] ipc error:', err.message);
		closeBoth();
	});

	ipc.on('close', () => {
		closeBoth();
	});

	ws.on('message', (raw) => {
		const text = raw.toString('utf8').trim();
		if (!text || ipc.destroyed) return;
		for (const line of text.split('\n')) {
			const msg = line.trim();
			if (msg) ipc.write(`${msg}\n`);
		}
	});

	ws.on('close', closeBoth);
	ws.on('error', closeBoth);
}

const wss = new WebSocketServer({ host: WS_HOST, port: WS_PORT });

wss.on('listening', () => {
	// eslint-disable-next-line no-console
	console.log(
		`[conet-ws-bridge] listening ws://${WS_HOST}:${WS_PORT} -> ipc:${GETH_IPC}`,
	);
});

wss.on('connection', attachIpcToWebSocket);

wss.on('error', (err) => {
	// eslint-disable-next-line no-console
	console.error('[conet-ws-bridge] server error:', err);
	process.exit(1);
});
