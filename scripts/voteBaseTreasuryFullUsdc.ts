/**
 * Miner 对 BaseTreasury 发起 vote：将国库内全部 USDC 转给指定地址（首票），
 * 或与已存在提案参数一致（后续票）。
 *
 * 私钥优先级（与 deployBaseTreasury 一致）：~/.master.json settle_contractAdmin[0] > 环境变量 PRIVATE_KEY
 * 运行: npx hardhat run scripts/voteBaseTreasuryFullUsdc.ts --network base
 *
 * 环境变量:
 *   PROPOSAL_TX_HASH 或 TX_HASH — 提案键 bytes32（必填）
 *   RECIPIENT — 收款地址（必填）
 */
import { network } from "hardhat"
import { getAddress, isAddress } from "ethers"
import * as fs from "fs"
import * as path from "path"
import { homedir } from "os"

const BASE_TREASURY = "0x5c64a8b0935DA72d60933bBD8cD10579E1C40c58"
const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

function resolveProposalTxHash(): `0x${string}` {
  const raw = (process.env.PROPOSAL_TX_HASH || process.env.TX_HASH || "").trim()
  if (!raw) {
    throw new Error("Set PROPOSAL_TX_HASH or TX_HASH (proposal key bytes32)")
  }
  const hex = raw.startsWith("0x") ? raw.slice(2) : raw
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) {
    throw new Error("PROPOSAL_TX_HASH / TX_HASH must be 32-byte hex")
  }
  return `0x${hex}` as `0x${string}`
}

function resolveRecipient(): `0x${string}` {
  const r = (process.env.RECIPIENT || "").trim()
  if (!r) {
    throw new Error("Set RECIPIENT")
  }
  if (!isAddress(r)) {
    throw new Error("RECIPIENT is not a valid address")
  }
  return getAddress(r) as `0x${string}`
}

function resolveMinerPk(): string {
  const setupPath = path.join(homedir(), ".master.json")
  if (fs.existsSync(setupPath)) {
    try {
      const data = JSON.parse(fs.readFileSync(setupPath, "utf-8")) as {
        settle_contractAdmin?: string[]
      }
      const pk = data.settle_contractAdmin?.[0]?.trim()
      if (pk) {
        return pk.startsWith("0x") ? pk : `0x${pk}`
      }
    } catch {
      /* fall through to PRIVATE_KEY */
    }
  }
  const fromEnv = process.env.PRIVATE_KEY?.trim()
  if (fromEnv) {
    return fromEnv.startsWith("0x") ? fromEnv : `0x${fromEnv}`
  }
  throw new Error(
    "Configure ~/.master.json settle_contractAdmin[0] (preferred) or set PRIVATE_KEY in .env"
  )
}

async function main() {
  const { ethers } = await network.connect()

  const PROPOSAL_TX_HASH = resolveProposalTxHash()
  const RECIPIENT = resolveRecipient()

  const pk = resolveMinerPk()
  const signer = new ethers.Wallet(pk, ethers.provider)

  const treasury = await ethers.getContractAt("BaseTreasury", BASE_TREASURY, signer)
  const miner = await signer.getAddress()
  const ok = await treasury.isMiner(miner)
  if (!ok) {
    throw new Error(`Signer ${miner} is not a BaseTreasury miner`)
  }

  const [, propToken, propRecipient, propAmount, voteCount, executed] = await treasury.getProposal(PROPOSAL_TX_HASH)

  if (executed) {
    console.log("Proposal already executed, skipping vote.")
    console.log({ proposalKey: PROPOSAL_TX_HASH })
    return
  }

  let amount: bigint
  if (propAmount > 0n) {
    if (propRecipient.toLowerCase() !== RECIPIENT.toLowerCase() || propToken.toLowerCase() !== BASE_USDC.toLowerCase()) {
      throw new Error(
        `Existing proposal mismatch: on-chain recipient ${propRecipient} token ${propToken} amount ${propAmount}; env RECIPIENT ${RECIPIENT}`
      )
    }
    amount = propAmount
    console.log("Joining existing proposal; using on-chain amount:", amount.toString())
  } else {
    amount = await treasury.erc20Balance(BASE_USDC)
    if (amount === 0n) {
      throw new Error("BaseTreasury USDC balance is zero (first vote)")
    }
    console.log("First vote: using full treasury USDC balance.")
  }

  console.log("Miner:", miner)
  console.log("USDC amount (raw):", amount.toString())
  console.log("USDC (6 decimals):", ethers.formatUnits(amount, 6))
  console.log("Recipient:", RECIPIENT)
  console.log("Proposal key:", PROPOSAL_TX_HASH)
  console.log("Current voteCount:", voteCount?.toString?.())

  const tx = await treasury.vote(PROPOSAL_TX_HASH, false, BASE_USDC, RECIPIENT, amount)
  console.log("vote tx:", tx.hash)
  await tx.wait()
  const [, , , , vc, ex] = await treasury.getProposal(PROPOSAL_TX_HASH)
  const required = await treasury.requiredVotes()
  console.log("done. voteCount:", vc?.toString?.(), "/", required.toString(), "executed:", !!ex)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
