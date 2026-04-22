import { network as networkModule } from "hardhat"

const CARD = "0x52aF5f5E7C136cc1BD596d64CB44eB7F5c9D2d6c"
const POINTS_ID = 0n

async function main() {
  const { ethers } = await networkModule.connect()
  const provider = ethers.provider

  const head = await provider.getBlockNumber()
  console.log("head block:", head)

  const erc1155 = new ethers.Interface([
    "event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)",
    "event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)"
  ])

  const tsTopic = erc1155.getEvent("TransferSingle")!.topicHash
  const tbTopic = erc1155.getEvent("TransferBatch")!.topicHash

  const PAGE = 9_500n
  let from = 0n
  // Card has bytecode → it was deployed at some block. Walk backward from head in pages until 0.
  // Faster: try a small recent window first
  const ranges: Array<[bigint, bigint]> = []
  let cur = BigInt(head)
  while (cur > 0n) {
    const lo = cur > PAGE ? cur - PAGE + 1n : 0n
    ranges.push([lo, cur])
    cur = lo - 1n
    if (ranges.length > 500) break // safety
  }

  console.log("scanning", ranges.length, "windows of", PAGE, "blocks...")

  type Row = { block: number; tx: string; from: string; to: string; value: bigint; logIdx: number }
  const rows: Row[] = []

  let scanned = 0
  for (const [lo, hi] of ranges) {
    try {
      const logs = await provider.getLogs({
        address: CARD,
        fromBlock: Number(lo),
        toBlock: Number(hi),
        topics: [[tsTopic, tbTopic]],
      })
      for (const lg of logs) {
        if (lg.topics[0] === tsTopic) {
          const parsed = erc1155.parseLog({ topics: [...lg.topics], data: lg.data })!
          if (BigInt(parsed.args.id) !== POINTS_ID) continue
          rows.push({
            block: lg.blockNumber,
            tx: lg.transactionHash,
            from: ethers.getAddress(parsed.args.from),
            to: ethers.getAddress(parsed.args.to),
            value: BigInt(parsed.args.value),
            logIdx: lg.index,
          })
        } else {
          const parsed = erc1155.parseLog({ topics: [...lg.topics], data: lg.data })!
          const ids: bigint[] = parsed.args.ids.map((x: any) => BigInt(x))
          const vals: bigint[] = parsed.args.values.map((x: any) => BigInt(x))
          for (let i = 0; i < ids.length; i++) {
            if (ids[i] !== POINTS_ID) continue
            rows.push({
              block: lg.blockNumber,
              tx: lg.transactionHash,
              from: ethers.getAddress(parsed.args.from),
              to: ethers.getAddress(parsed.args.to),
              value: vals[i],
              logIdx: lg.index,
            })
          }
        }
      }
      scanned += 1
      if (scanned % 20 === 0) process.stdout.write(`  scanned ${scanned}/${ranges.length}, found=${rows.length}, lo=${lo}\n`)
      if (rows.length > 0 && hi < BigInt(head) - 200n && scanned > 5) {
        // already got something recent, but keep going to get full history; comment out to stop early
      }
    } catch (e) {
      console.log(`  range ${lo}-${hi} failed:`, (e as Error).message)
    }
  }

  rows.sort((a, b) => a.block - b.block || a.logIdx - b.logIdx)
  console.log("\ntotal token#0 transfer events:", rows.length)
  for (const r of rows) {
    const fmt = (v: bigint) => `${v}/${(v / 1_000_000n).toString()}.${(v % 1_000_000n).toString().padStart(6, '0')}`
    const tag = r.from === ethers.ZeroAddress ? "MINT" : (r.to === ethers.ZeroAddress ? "BURN" : "XFER")
    console.log(`  blk=${r.block} ${tag} from=${r.from} to=${r.to} value=${fmt(r.value)} tx=${r.tx}`)
  }
}

main().catch((e) => { console.error(e); process.exit(1) })
