/**
 * Miner 对 BaseTreasury 发起 vote：将国库内全部 USDC 转给指定地址。
 * 私钥优先级：环境变量 PRIVATE_KEY > ~/.master.json settle_contractAdmin[0]（与 deployBaseTreasury 一致）
 * 运行: npx hardhat run scripts/voteBaseTreasuryFullUsdc.ts --network base
 */
import { network } from "hardhat"
import * as fs from "fs"
import * as path from "path"
import { homedir } from "os"

const BASE_TREASURY = "0x5c64a8b0935DA72d60933bBD8cD10579E1C40c58"
const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
/** 提案键（与 CoNET 出金等业务约定的 bytes32） */
const PROPOSAL_TX_HASH = "0xe8dd6767e02111c8ff52420300ccc10b895cb2dceedc70360c8acde7193beafb"
const RECIPIENT = "0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61"

function resolveMinerPk(): string {
  const fromEnv = process.env.PRIVATE_KEY?.trim()
  if (fromEnv) {
    return fromEnv.startsWith("0x") ? fromEnv : `0x${fromEnv}`
  }
  const setupPath = path.join(homedir(), ".master.json")
  if (!fs.existsSync(setupPath)) {
    throw new Error("Set PRIVATE_KEY in .env or configure ~/.master.json settle_contractAdmin[0]")
  }
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8")) as {
    settle_contractAdmin?: string[]
  }
  const pk = data.settle_contractAdmin?.[0]
  if (!pk) {
    throw new Error("~/.master.json settle_contractAdmin[0] missing")
  }
  return pk.startsWith("0x") ? pk : `0x${pk}`
}

async function main() {
  const { ethers } = (await network.connect()) as unknown as {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ethers: any
  }
  const pk = resolveMinerPk()
  const signer = new ethers.Wallet(pk, ethers.provider)

  const treasury = await ethers.getContractAt("BaseTreasury", BASE_TREASURY, signer)
  const miner = await signer.getAddress()
  const ok = await treasury.isMiner(miner)
  if (!ok) {
    throw new Error(`Signer ${miner} is not a BaseTreasury miner`)
  }
  const amount = await treasury.erc20Balance(BASE_USDC)
  if (amount === 0n) {
    throw new Error("BaseTreasury USDC balance is zero")
  }
  console.log("Miner:", miner)
  console.log("USDC balance (raw):", amount.toString())
  console.log("USDC (6 decimals):", ethers.formatUnits(amount, 6))
  console.log("Recipient:", RECIPIENT)
  console.log("Proposal key:", PROPOSAL_TX_HASH)

  const tx = await treasury.vote(PROPOSAL_TX_HASH, false, BASE_USDC, RECIPIENT, amount)
  console.log("vote tx:", tx.hash)
  await tx.wait()
  console.log("done")
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
