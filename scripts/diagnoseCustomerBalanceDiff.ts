/**
 * 排查 Card 0x52aF…d6c 上 token#0 的所有 TransferSingle / TransferBatch 事件，
 * 找出 49.992039 vs 50 之间 0.007961 的去向。
 *
 * 用法：
 *   npx hardhat run scripts/diagnoseCustomerBalanceDiff.ts --network base
 * 可选：CARD=0x... TOKEN=0
 */
import { ethers } from "ethers"

const CARD = (process.env.CARD || "0x52aF5f5E7C136cc1BD596d64CB44eB7F5c9D2d6c").trim()
const TOKEN_ID = BigInt(process.env.TOKEN || "0")
const RPC = process.env.BASE_RPC_URL || "https://base.llamarpc.com"
const CHUNK = Number(process.env.CHUNK || 5000)
const E6 = 1_000_000n
const fmt = (raw: bigint): string => {
	const w = raw / E6
	const f = (raw % E6).toString().padStart(6, "0")
	return `${w}.${f}`
}

const ZERO = "0x0000000000000000000000000000000000000000"

/** 二分搜索：找到首次出现合约 code 的最早区块（即部署区块） */
async function findDeploymentBlock(provider: ethers.Provider, addr: string): Promise<number> {
	let lo = 0
	let hi = await provider.getBlockNumber()
	const headCode = await provider.getCode(addr, hi)
	if (!headCode || headCode === "0x") throw new Error("no code at head")
	while (lo < hi) {
		const mid = Math.floor((lo + hi) / 2)
		const code = await provider.getCode(addr, mid)
		if (code && code !== "0x" && code.length > 2) hi = mid
		else lo = mid + 1
	}
	return lo
}

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	console.log("RPC :", RPC)

	const card = new ethers.Contract(
		CARD,
		[
			"event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)",
			"event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)",
			"function totalSupply(uint256 id) view returns (uint256)",
		],
		provider,
	)

	const head = await provider.getBlockNumber()
	console.log("Card    :", CARD)
	console.log("token id:", TOKEN_ID.toString())
	console.log("head    :", head)
	const deployBlock = await findDeploymentBlock(provider, CARD)
	console.log("deployBlock:", deployBlock)

	const filterSingle = card.filters.TransferSingle()
	const filterBatch = card.filters.TransferBatch()

	const single: any[] = []
	const batch: any[] = []
	for (let from = deployBlock; from <= head; from += CHUNK) {
		const to = Math.min(from + CHUNK - 1, head)
		const [s, b] = await Promise.all([
			card.queryFilter(filterSingle, from, to),
			card.queryFilter(filterBatch, from, to),
		])
		single.push(...s)
		batch.push(...b)
	}
	console.log("TransferSingle events:", single.length)
	console.log("TransferBatch  events:", batch.length)

	type Row = {
		block: number
		tx: string
		op: string
		from: string
		to: string
		value: bigint
		kind: "Single" | "Batch"
	}
	const rows: Row[] = []
	for (const ev of single) {
		const a = (ev as any).args
		if (BigInt(a.id) !== TOKEN_ID) continue
		rows.push({
			block: ev.blockNumber,
			tx: ev.transactionHash,
			op: a.operator,
			from: a.from,
			to: a.to,
			value: BigInt(a.value),
			kind: "Single",
		})
	}
	for (const ev of batch) {
		const a = (ev as any).args
		const ids: bigint[] = a.ids.map((x: any) => BigInt(x))
		const values: bigint[] = a.values.map((x: any) => BigInt(x))
		for (let i = 0; i < ids.length; i++) {
			if (ids[i] !== TOKEN_ID) continue
			rows.push({
				block: ev.blockNumber,
				tx: ev.transactionHash,
				op: a.operator,
				from: a.from,
				to: a.to,
				value: values[i],
				kind: "Batch",
			})
		}
	}
	rows.sort((a, b) => a.block - b.block || a.tx.localeCompare(b.tx))

	let mintTotal = 0n
	let burnTotal = 0n
	const balByAddr = new Map<string, bigint>()
	const bump = (addr: string, delta: bigint) => {
		const k = addr.toLowerCase()
		balByAddr.set(k, (balByAddr.get(k) ?? 0n) + delta)
	}
	console.log("\n#  block      tx                                                          kind     from  → to       value(token#0)")
	console.log("--------------------------------------------------------------------------------------------------------")
	rows.forEach((r, i) => {
		const fromShort = r.from === ZERO ? "MINT(0x0)" : r.from
		const toShort = r.to === ZERO ? "BURN(0x0)" : r.to
		console.log(
			`${String(i + 1).padStart(2)} ${r.block}  ${r.tx}  ${r.kind}   ${fromShort} → ${toShort}   ${fmt(r.value)} (${r.value.toString()})`,
		)
		if (r.from === ZERO) mintTotal += r.value
		else bump(r.from, -r.value)
		if (r.to === ZERO) burnTotal += r.value
		else bump(r.to, r.value)
	})

	const supply = BigInt((await card.totalSupply(TOKEN_ID)).toString())
	console.log("\n累计：")
	console.log("  Σ Mint  :", fmt(mintTotal), `(raw ${mintTotal})`)
	console.log("  Σ Burn  :", fmt(burnTotal), `(raw ${burnTotal})`)
	console.log("  Σ Mint − Σ Burn =", fmt(mintTotal - burnTotal), `(raw ${mintTotal - burnTotal})`)
	console.log("  totalSupply(now)=", fmt(supply), `(raw ${supply})`)

	console.log("\n各地址当前账户净值 (按事件累计):")
	const sorted = [...balByAddr.entries()].sort((a, b) => (b[1] > a[1] ? 1 : -1))
	for (const [k, v] of sorted) {
		console.log("  ", k, "=", fmt(v), `(raw ${v})`)
	}
}

main().catch((e) => {
	console.error("失败:", e)
	process.exit(1)
})
