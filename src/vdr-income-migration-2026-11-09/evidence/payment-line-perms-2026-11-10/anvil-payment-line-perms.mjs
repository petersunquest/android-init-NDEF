#!/usr/bin/env node
/**
 * Payment-line permission negative tests (lab / Anvil only).
 * Compiles contracts under ./contracts via forge, deploys dual-line fixtures,
 * asserts escalate / cross-line / revoke mid-flight / gas-cap behavior.
 */
import { spawn, spawnSync } from 'node:child_process'
import { createWriteStream } from 'node:fs'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import net from 'node:net'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { ethers } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const CONTRACTS = path.join(__dirname, 'contracts')
const RESULTS_DIR = path.join(__dirname, 'results')
const ANVIL_PORT = 18549
const ANVIL_URL = `http://127.0.0.1:${ANVIL_PORT}`

const MAX_PAYOUT = ethers.parseEther('2')
const MAX_BATCH = ethers.parseEther('50')
const MAX_GAS_TOPUP = ethers.parseEther('0.1')
const MAX_GAS_PERIOD = ethers.parseEther('0.5')
const GAS_PERIOD_SEC = 86400n

const LINE_A = ethers.id('payment-line-A')
const LINE_B = ethers.id('payment-line-B')

const results = []

function record(id, title, ok, detail) {
	results.push({ id, title, ok: !!ok, detail: detail ?? '' })
	console.log(`[${ok ? 'PASS' : 'FAIL'}] ${id} ${title}${detail ? ` — ${detail}` : ''}`)
}

function portFree(port) {
	return new Promise((resolve) => {
		const s = net.createServer()
		s.once('error', () => resolve(false))
		s.once('listening', () => s.close(() => resolve(true)))
		s.listen(port, '127.0.0.1')
	})
}

async function waitRpc(url, attempts = 80) {
	for (let i = 0; i < attempts; i++) {
		try {
			const provider = new ethers.JsonRpcProvider(url, 31337, { staticNetwork: true })
			const n = await provider.getBlockNumber()
			if (typeof n === 'number' || typeof n === 'bigint') return provider
		} catch {
			/* retry */
		}
		await new Promise((r) => setTimeout(r, 150))
	}
	throw new Error(`anvil RPC not ready: ${url}`)
}

function extractRevertData(e) {
	const candidates = [e?.data, e?.error?.data, e?.info?.error?.data]
	for (const c of candidates) {
		if (typeof c === 'string' && c.startsWith('0x') && c.length >= 10) return c
		if (c && typeof c === 'object' && typeof c.data === 'string') return c.data
	}
	const nested = e?.info?.error?.message || e?.error?.message || ''
	const m = String(nested).match(/0x[0-9a-fA-F]{8,}/)
	return m ? m[0] : null
}

function decodeRevert(e, ifaces = []) {
	const data = extractRevertData(e)
	if (data) {
		for (const iface of ifaces) {
			try {
				const parsed = iface.parseError(data)
				if (parsed) return `${parsed.name}(${parsed.args.map(String).join(',')})`
			} catch {
				/* next */
			}
		}
		return `customError sel=${data.slice(0, 10)}`
	}
	return String(e?.shortMessage || e?.reason || e?.message || e).slice(0, 220)
}

async function expectRevert(label, fn, ifaces = []) {
	try {
		const tx = await fn()
		if (tx && typeof tx.wait === 'function') await tx.wait()
		return { ok: false, detail: `${label}: expected revert, got success` }
	} catch (e) {
		return { ok: true, detail: decodeRevert(e, ifaces) }
	}
}

async function expectSuccess(label, fn) {
	try {
		const tx = await fn()
		if (tx && typeof tx.wait === 'function') await tx.wait()
		return { ok: true, detail: 'ok' }
	} catch (e) {
		return { ok: false, detail: `${label}: ${decodeRevert(e)}` }
	}
}

/** Raw eth_getBalance — avoids ethers v6 JsonRpcProvider latest-block cache stale reads. */
async function ethBalance(provider, addr, blockTag = 'latest') {
	const tag =
		typeof blockTag === 'number' || typeof blockTag === 'bigint'
			? ethers.toQuantity(blockTag)
			: blockTag
	const hex = await provider.send('eth_getBalance', [ethers.getAddress(addr), tag])
	return BigInt(hex)
}

function decodeNamedEvent(iface, receipt, name) {
	if (!receipt?.logs?.length) return null
	for (const log of receipt.logs) {
		try {
			const parsed = iface.parseLog(log)
			if (parsed?.name === name) return parsed
		} catch {
			/* next */
		}
	}
	return null
}

function forgeBuild() {
	const r = spawnSync('forge', ['build', '--root', CONTRACTS], {
		encoding: 'utf8',
		cwd: CONTRACTS,
	})
	if (r.status !== 0) {
		throw new Error(`forge build failed:\n${r.stderr || r.stdout}`)
	}
}

async function loadForgeArtifact(contractFile, contractName) {
	const artPath = path.join(CONTRACTS, 'out', contractFile, `${contractName}.json`)
	const raw = JSON.parse(await readFile(artPath, 'utf8'))
	return { abi: raw.abi, bytecode: raw.bytecode?.object || raw.bytecode }
}

async function main() {
	await mkdir(RESULTS_DIR, { recursive: true })
	const logPath = path.join(RESULTS_DIR, 'anvil-payment-line-perms.log')
	const jsonPath = path.join(RESULTS_DIR, 'anvil-payment-line-perms.json')
	const logStream = createWriteStream(logPath, { flags: 'w' })
	const origLog = console.log
	console.log = (...args) => {
		origLog(...args)
		logStream.write(args.map(String).join(' ') + '\n')
	}

	console.log('forge build…')
	forgeBuild()

	if (!(await portFree(ANVIL_PORT))) {
		throw new Error(`port ${ANVIL_PORT} busy — refuse to attach to foreign node`)
	}

	const anvil = spawn(
		'anvil',
		[
			'--host',
			'127.0.0.1',
			'--port',
			String(ANVIL_PORT),
			'--chain-id',
			'31337',
			'--accounts',
			'12',
			'--balance',
			'10000',
		],
		{ stdio: ['ignore', 'pipe', 'pipe'] }
	)
	anvil.stderr.on('data', (d) => logStream.write(`[anvil.err] ${d}`))
	anvil.stdout.on('data', (d) => logStream.write(`[anvil.out] ${d}`))

	let exitEarly = false
	try {
		const provider = await waitRpc(ANVIL_URL)
		const accounts = await provider.send('eth_accounts', [])
		if (accounts.length < 8) throw new Error('anvil accounts < 8')

		const owner = await provider.getSigner(accounts[0])
		const pm = await provider.getSigner(accounts[1])
		const memberA = await provider.getSigner(accounts[2])
		const memberB = await provider.getSigner(accounts[3])
		const stranger = await provider.getSigner(accounts[4])
		// accounts[5] reserved
		const ownerAddr = await owner.getAddress()
		const pmAddr = await pm.getAddress()
		const memberAAddr = await memberA.getAddress()
		const memberBAddr = await memberB.getAddress()
		const strangerAddr = await stranger.getAddress()

		const mockArt = await loadForgeArtifact('MockVdrPaymentLine.sol', 'MockVdrPaymentLine')
		const sinkArt = await loadForgeArtifact('LabPoolSink.sol', 'LabPoolSink')
		const execArt = await loadForgeArtifact(
			'LabLineMemberManagedExecutor.sol',
			'LabLineMemberManagedExecutor'
		)

		const MockFactory = new ethers.ContractFactory(mockArt.abi, mockArt.bytecode, owner)
		const SinkFactory = new ethers.ContractFactory(sinkArt.abi, sinkArt.bytecode, owner)
		const ExecFactory = new ethers.ContractFactory(execArt.abi, execArt.bytecode, owner)

		const mockVdr = await MockFactory.deploy(ownerAddr)
		await mockVdr.waitForDeployment()
		const sinkA = await SinkFactory.deploy()
		await sinkA.waitForDeployment()
		const sinkB = await SinkFactory.deploy()
		await sinkB.waitForDeployment()

		const deployExec = async (sink, lineId) => {
			const c = await ExecFactory.deploy(
				ownerAddr,
				await mockVdr.getAddress(),
				await sink.getAddress(),
				lineId,
				MAX_PAYOUT,
				MAX_BATCH,
				MAX_GAS_TOPUP,
				MAX_GAS_PERIOD,
				GAS_PERIOD_SEC
			)
			await c.waitForDeployment()
			return c
		}

		const execA = await deployExec(sinkA, LINE_A)
		const execB = await deployExec(sinkB, LINE_B)

		// Fund gas purses + settlement balances
		await (
			await owner.sendTransaction({
				to: await execA.getAddress(),
				value: ethers.parseEther('20'),
			})
		).wait()
		await (
			await owner.sendTransaction({
				to: await execB.getAddress(),
				value: ethers.parseEther('20'),
			})
		).wait()

		// Wire PM as memberManager on both lines (owner action)
		await (await execA.setMemberManager(pmAddr)).wait()
		await (await execB.setMemberManager(pmAddr)).wait()

		// PM adds line members (cross-line distinct)
		await (await execA.connect(pm).setMember(memberAAddr, true)).wait()
		await (await execB.connect(pm).setMember(memberBAddr, true)).wait()

		const execIface = new ethers.Interface(execArt.abi)
		const mockIface = new ethers.Interface(mockArt.abi)
		const decodeIfaces = [execIface, mockIface]

		console.log(
			`deployed vdr=${await mockVdr.getAddress()} execA=${await execA.getAddress()} execB=${await execB.getAddress()}`
		)
		console.log(
			`roles owner=${ownerAddr} pm=${pmAddr} memberA=${memberAAddr} memberB=${memberBAddr} stranger=${strangerAddr}`
		)

		// ─── Happy path: memberA payouts on line A ───
		{
			const r = await expectSuccess('memberA payoutBatch A', () =>
				execA
					.connect(memberA)
					.payoutBatch(ethers.id('batch-a-1'), ethers.id('event-a-1'), [
						ethers.parseEther('1'),
					])
			)
			record('H1', 'memberA payoutBatch on ExecA', r.ok, r.detail)
		}

		// ─── Escalate: PM must FAIL VDR addAdmin / setRedeemAdmin / withdraw ───
		{
			const r1 = await expectRevert(
				'PM addAdmin',
				() => mockVdr.connect(pm).addAdmin(pmAddr),
				decodeIfaces
			)
			record('E1', 'PM addAdmin on MockVDR → FAIL', r1.ok, r1.detail)

			const r2 = await expectRevert(
				'PM setRedeemAdmin',
				() => mockVdr.connect(pm).setRedeemAdmin(pmAddr, true),
				decodeIfaces
			)
			record('E2', 'PM setRedeemAdmin on MockVDR → FAIL', r2.ok, r2.detail)

			const r3 = await expectRevert(
				'PM withdrawNative',
				() => mockVdr.connect(pm).withdrawNative(pmAddr, 1n),
				decodeIfaces
			)
			record('E3', 'PM withdrawNative on MockVDR → FAIL', r3.ok, r3.detail)
		}

		// ─── Escalate: member / stranger must FAIL owner surfaces on executor ───
		{
			const r1 = await expectRevert(
				'PM setCaps',
				() =>
					execA
						.connect(pm)
						.setCaps(MAX_PAYOUT, MAX_BATCH, MAX_GAS_TOPUP, MAX_GAS_PERIOD, GAS_PERIOD_SEC),
				decodeIfaces
			)
			record('E4', 'PM setCaps on ExecA → FAIL', r1.ok, r1.detail)

			const r2 = await expectRevert(
				'PM transferOwnership',
				() => execA.connect(pm).transferOwnership(pmAddr),
				decodeIfaces
			)
			record('E5', 'PM transferOwnership ExecA → FAIL', r2.ok, r2.detail)

			const r3 = await expectRevert(
				'member setMemberManager',
				() => execA.connect(memberA).setMemberManager(memberAAddr),
				decodeIfaces
			)
			record('E6', 'memberA setMemberManager → FAIL', r3.ok, r3.detail)

			const r4 = await expectRevert(
				'stranger setMember',
				() => execA.connect(stranger).setMember(strangerAddr, true),
				decodeIfaces
			)
			record('E7', 'stranger setMember → FAIL', r4.ok, r4.detail)
		}

		// ─── Cross-line isolation ───
		{
			const r1 = await expectRevert(
				'memberA payout on B',
				() =>
					execB
						.connect(memberA)
						.payoutBatch(ethers.id('batch-x-1'), ethers.id('event-x-1'), [
							ethers.parseEther('1'),
						]),
				decodeIfaces
			)
			record('X1', 'memberA payoutBatch on ExecB → FAIL', r1.ok, r1.detail)

			const r2 = await expectRevert(
				'memberB payout on A',
				() =>
					execA
						.connect(memberB)
						.payoutBatch(ethers.id('batch-x-2'), ethers.id('event-x-2'), [
							ethers.parseEther('1'),
						]),
				decodeIfaces
			)
			record('X2', 'memberB payoutBatch on ExecA → FAIL', r2.ok, r2.detail)

			// PM can still manage members on B (same PM, different line)
			const r3 = await expectSuccess('PM setMember on B', () =>
				execB.connect(pm).setMember(strangerAddr, true)
			)
			record('X3', 'PM setMember on ExecB (same PM, other line)', r3.ok, r3.detail)
			await (await execB.connect(pm).setMember(strangerAddr, false)).wait()
		}

		// ─── Gas top-up: PM OK for member; FAIL for non-member / over cap ───
		{
			const topUpAmt = ethers.parseEther('0.05')
			const execAAddr = await execA.getAddress()
			const purseBefore = await ethBalance(provider, execAAddr)
			const memberBefore = await ethBalance(provider, memberAAddr)
			let topUpReceipt = null
			const r1 = await expectSuccess('PM topUp memberA', async () => {
				const tx = await execA.connect(pm).topUpMemberGas(memberAAddr, topUpAmt)
				topUpReceipt = await tx.wait()
				return topUpReceipt
			})
			record('G1', 'PM topUpMemberGas(memberA) → PASS', r1.ok, r1.detail)
			if (r1.ok && topUpReceipt) {
				const bn = topUpReceipt.blockNumber
				const purseAfter = await ethBalance(provider, execAAddr, bn)
				const memberAfter = await ethBalance(provider, memberAAddr, bn)
				const purseDelta = purseBefore - purseAfter
				const memberDelta = memberAfter - memberBefore
				const gasEvt = decodeNamedEvent(execIface, topUpReceipt, 'GasTopUp')
				const evtAmt = gasEvt ? BigInt(gasEvt.args.amount.toString()) : 0n
				const viewPurse = await execA.gasPurseBalance()
				record(
					'G1b',
					'gas purse decreased + member credited',
					purseDelta === topUpAmt && memberDelta === topUpAmt && evtAmt === topUpAmt,
					`purseDelta=${purseDelta.toString()} memberDelta=${memberDelta.toString()} evtAmt=${evtAmt.toString()} viewPurse=${viewPurse.toString()} block=${bn}`
				)
			}

			const r2 = await expectRevert(
				'topUp stranger',
				() => execA.connect(pm).topUpMemberGas(strangerAddr, ethers.parseEther('0.01')),
				decodeIfaces
			)
			record('G2', 'PM topUpMemberGas(stranger) → FAIL', r2.ok, r2.detail)

			const r3 = await expectRevert(
				'topUp over per-tx',
				() => execA.connect(pm).topUpMemberGas(memberAAddr, ethers.parseEther('0.2')),
				decodeIfaces
			)
			record('G3', 'PM topUp > maxGasTopUpWei → FAIL', r3.ok, r3.detail)

			const r4 = await expectRevert(
				'member topUp self',
				() => execA.connect(memberA).topUpMemberGas(memberAAddr, ethers.parseEther('0.01')),
				decodeIfaces
			)
			record('G4', 'memberA topUpMemberGas → FAIL', r4.ok, r4.detail)
		}

		// ─── Revoke mid-flight: after revoke, next payout FAIL; prior batch stays ───
		{
			const preAmt = ethers.parseEther('0.5')
			const sinkAAddr = await sinkA.getAddress()
			const execAAddr = await execA.getAddress()
			const sinkBalBefore = await ethBalance(provider, sinkAAddr)
			const execBalBefore = await ethBalance(provider, execAAddr)
			const preTx = await execA
				.connect(memberA)
				.payoutBatch(ethers.id('batch-a-pre-revoke'), ethers.id('event-a-pre-revoke'), [preAmt])
			const preRcpt = await preTx.wait()
			if (preRcpt.status !== 1) throw new Error('pre-revoke payout status!=1')
			const bn = preRcpt.blockNumber
			const sinkBalMid = await ethBalance(provider, sinkAAddr, bn)
			const execBalMid = await ethBalance(provider, execAAddr, bn)
			const payEvt = decodeNamedEvent(execIface, preRcpt, 'PayoutBatch')
			const evtTotal = payEvt ? BigInt(payEvt.args.totalWei.toString()) : 0n
			record(
				'R0',
				'payout before revoke credited sinkA',
				sinkBalMid === sinkBalBefore + preAmt &&
					execBalMid === execBalBefore - preAmt &&
					evtTotal === preAmt,
				`sinkBefore=${sinkBalBefore} sinkMid=${sinkBalMid} execDelta=${(execBalBefore - execBalMid).toString()} evtTotal=${evtTotal.toString()} block=${bn}`
			)

			await (await execA.connect(pm).setMember(memberAAddr, false)).wait()
			const stillMember = await execA.members(memberAAddr)
			record('R1', 'memberA revoked (members=false)', stillMember === false, `members=${stillMember}`)

			const r2 = await expectRevert(
				'payout after revoke',
				() =>
					execA
						.connect(memberA)
						.payoutBatch(ethers.id('batch-a-post-revoke'), ethers.id('event-a-post-revoke'), [
							ethers.parseEther('0.5'),
						]),
				decodeIfaces
			)
			record('R2', 'memberA payoutBatch after revoke → FAIL', r2.ok, r2.detail)

			const sinkBalAfter = await ethBalance(provider, sinkAAddr)
			record(
				'R3',
				'sinkA unchanged after failed post-revoke payout',
				sinkBalAfter === sinkBalMid,
				`sink=${sinkBalAfter.toString()}`
			)

			// Re-add for cleanliness of remaining tests
			await (await execA.connect(pm).setMember(memberAAddr, true)).wait()
		}

		// ─── Owner retains setMemberManager; PM cannot reassign manager ───
		{
			const r1 = await expectRevert(
				'PM setMemberManager',
				() => execA.connect(pm).setMemberManager(strangerAddr),
				decodeIfaces
			)
			record('O1', 'PM setMemberManager → FAIL', r1.ok, r1.detail)

			const r2 = await expectSuccess('owner setPaused', () => execA.connect(owner).setPaused(true))
			record('O2', 'owner setPaused(true)', r2.ok, r2.detail)

			const r3 = await expectRevert(
				'payout while paused',
				() =>
					execA
						.connect(memberA)
						.payoutBatch(ethers.id('batch-paused'), ethers.id('event-paused'), [
							ethers.parseEther('0.1'),
						]),
				decodeIfaces
			)
			record('O3', 'member payout while paused → FAIL', r3.ok, r3.detail)
			await (await execA.connect(owner).setPaused(false)).wait()
		}

		// ─── Member cannot escalate to MockVDR admin ───
		{
			const r = await expectRevert(
				'member addAdmin',
				() => mockVdr.connect(memberA).addAdmin(memberAAddr),
				decodeIfaces
			)
			record('E8', 'memberA MockVDR addAdmin → FAIL', r.ok, r.detail)
		}

		const passed = results.filter((x) => x.ok).length
		const failed = results.filter((x) => !x.ok).length
		const summary = {
			ok: failed === 0,
			passed,
			failed,
			total: results.length,
			anvilPort: ANVIL_PORT,
			contracts: {
				mockVdr: await mockVdr.getAddress(),
				execA: await execA.getAddress(),
				execB: await execB.getAddress(),
				sinkA: await sinkA.getAddress(),
				sinkB: await sinkB.getAddress(),
			},
			roles: {
				owner: ownerAddr,
				pm: pmAddr,
				memberA: memberAAddr,
				memberB: memberBAddr,
				stranger: strangerAddr,
			},
			lineIds: { A: LINE_A, B: LINE_B },
			results,
			generatedAt: new Date().toISOString(),
			note: 'Lab/Anvil only. Production STATUS QUO — see PROD-PENDING-REVIEW-STATUS-QUO.md',
		}

		await writeFile(jsonPath, JSON.stringify(summary, null, 2) + '\n')
		console.log(`\nsummary passed=${passed} failed=${failed} → ${jsonPath}`)
		if (failed > 0) process.exitCode = 1
	} finally {
		exitEarly = true
		anvil.kill('SIGTERM')
		await new Promise((r) => setTimeout(r, 300))
		try {
			anvil.kill('SIGKILL')
		} catch {
			/* ignore */
		}
		logStream.end()
		console.log = origLog
	}
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
