/**
 * 拉取 Charge tx 细节，找出 49.992039 是怎么算出来的（vs 50.000000）。
 *
 * tx = 0x54046fac2bb4f75d1ba631fb677f7723c2d59c57842352622368bd98965c7042（Base）
 *   Customer 0xCf93…1769  →  AA 0x7370…210D   token#0  49.992039
 */
import { ethers } from "ethers"

const RPC = process.env.BASE_RPC_URL || "https://mainnet.base.org"
const TX = (process.env.TX || "0x54046fac2bb4f75d1ba631fb677f7723c2d59c57842352622368bd98965c7042").trim()

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	console.log("RPC:", RPC)
	console.log("TX :", TX)

	const tx = await provider.getTransaction(TX)
	const rcpt = await provider.getTransactionReceipt(TX)
	if (!tx || !rcpt) {
		console.log("tx 拿不到")
		process.exit(1)
	}
	console.log("\n--- tx ---")
	console.log("from:", tx.from)
	console.log("to  :", tx.to)
	console.log("input head:", tx.data.slice(0, 10), "(selector)")
	console.log("input full:", tx.data)
	console.log("\n--- receipt ---")
	console.log("status   :", rcpt.status)
	console.log("blockNum :", rcpt.blockNumber)
	console.log("gasUsed  :", rcpt.gasUsed.toString())
	console.log("logs     :", rcpt.logs.length)

	const ifaceCardSelectors: Record<string, string> = {}
	const cardAbi = [
		"function transferPoints(address to, uint256 amount)",
		"function transferPointsByAdmin(address from, address to, uint256 amount)",
		"function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes data)",
		"function safeBatchTransferFrom(address from, address to, uint256[] ids, uint256[] values, bytes data)",
		"function transfer(address to, uint256 amount)",
	]
	for (const sig of cardAbi) {
		const f = ethers.FunctionFragment.from(sig)
		ifaceCardSelectors[ethers.id(f.format("sighash")).slice(0, 10)] = sig
	}
	console.log("\nselector lookup table:")
	for (const [sel, sig] of Object.entries(ifaceCardSelectors)) console.log(" ", sel, sig)

	const sel = tx.data.slice(0, 10).toLowerCase()
	const matchSig = ifaceCardSelectors[sel]
	if (matchSig) {
		console.log("\n*** matched signature:", matchSig)
		const iface = new ethers.Interface([matchSig])
		const parsed = iface.parseTransaction({ data: tx.data, value: tx.value })
		console.log("args:", parsed?.args.map(String))
	}

	console.log("\n--- logs ---")
	for (let i = 0; i < rcpt.logs.length; i++) {
		const log = rcpt.logs[i]
		console.log(`#${i}  addr=${log.address}  topic0=${log.topics[0]}`)
		try {
			const iface = new ethers.Interface([
				"event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)",
				"event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)",
				"event Transfer(address indexed from, address indexed to, uint256 value)",
				"event Approval(address indexed owner, address indexed spender, uint256 value)",
			])
			const parsed = iface.parseLog({ topics: log.topics as string[], data: log.data })
			if (parsed) {
				console.log(
					"   parsed:",
					parsed.name,
					parsed.args.map((a) => (typeof a === "bigint" ? a.toString() : String(a))),
				)
			}
		} catch {
			console.log("   raw data:", log.data)
		}
	}
}

main().catch((e) => {
	console.error("fail:", e)
	process.exit(1)
})
