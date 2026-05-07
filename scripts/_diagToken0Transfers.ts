import { network as networkModule } from "hardhat"

const CARD = "0x52aF5f5E7C136cc1BD596d64CB44eB7F5c9D2d6c"
const POINTS_ID = 0n

async function main() {
  const { ethers } = await networkModule.connect()
  const provider = ethers.provider
  const head = BigInt(await provider.getBlockNumber())
  console.log("head:", head.toString())

  const erc1155 = new ethers.Interface([
    "event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)",
    "event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)"
  ])
  const tsTopic = erc1155.getEvent("TransferSingle")!.topicHash
  const tbTopic = erc1155.getEvent("TransferBatch")!.topicHash

  type Row = { block: number; tx: string; operator: string; from: string; to: string; value: bigint; logIdx: number }
  const rows: Row[] = []

  // Walk backward from head in pages of 10k until we've covered ~21 days (≈ 9_072_000 blks at 0.2s)
  const PAGE = 9_000n
  const MIN_BLOCK = head > 10_000_000n ? head - 10_000_000n : 0n // ~24 days
  let hi = head
  while (hi > MIN_BLOCK) {
    const lo = hi > PAGE ? hi - PAGE + 1n : 0n
    const start = lo < MIN_BLOCK ? MIN_BLOCK : lo
    try {
      const logs = await provider.getLogs({
        address: CARD,
        fromBlock: Number(start),
        toBlock: Number(hi),
        topics: [[tsTopic, tbTopic]],
      })
      for (const lg of logs) {
        if (lg.topics[0] === tsTopic) {
          const parsed = erc1155.parseLog({ topics: [...lg.topics], data: lg.data })!
          if (BigInt(parsed.args.id) !== POINTS_ID) continue
          rows.push({
            block: lg.blockNumber, tx: lg.transactionHash,
            operator: ethers.getAddress(parsed.args.operator),
            from: ethers.getAddress(parsed.args.from),
            to: ethers.getAddress(parsed.args.to),
            value: BigInt(parsed.args.value), logIdx: lg.index,
          })
        } else {
          const parsed = erc1155.parseLog({ topics: [...lg.topics], data: lg.data })!
          const ids: bigint[] = parsed.args.ids.map((x: any) => BigInt(x))
          const vals: bigint[] = parsed.args.values.map((x: any) => BigInt(x))
          for (let i = 0; i < ids.length; i++) {
            if (ids[i] !== POINTS_ID) continue
            rows.push({
              block: lg.blockNumber, tx: lg.transactionHash,
              operator: ethers.getAddress(parsed.args.operator),
              from: ethers.getAddress(parsed.args.from),
              to: ethers.getAddress(parsed.args.to),
              value: vals[i], logIdx: lg.index,
            })
          }
        }
      }
      hi = start - 1n
    } catch (e) {
      const msg = (e as Error).message
      console.log(`range ${start}-${hi} err: ${msg.slice(0, 100)}`)
      hi = start - 1n
    }
  }

  rows.sort((a, b) => a.block - b.block || a.logIdx - b.logIdx)
  console.log("\ntoken#0 transfer events:", rows.length)
  const fmt = (v: bigint) => `${(v / 1_000_000n).toString()}.${(v % 1_000_000n).toString().padStart(6, '0')}`
  for (const r of rows) {
    const tag = r.from === ethers.ZeroAddress ? "MINT" : (r.to === ethers.ZeroAddress ? "BURN" : "XFER")
    console.log(`  blk=${r.block} ${tag.padEnd(4)} value=${fmt(r.value).padStart(12)} from=${r.from} to=${r.to} op=${r.operator}`)
    console.log(`        tx=${r.tx}`)
  }
}

main().catch((e) => { console.error(e); process.exit(1) })
