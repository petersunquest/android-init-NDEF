/**
 * 将 masterSetup.settle_contractAdmin 的钱包地址登记为 BUnitAirdrop 的 admin
 *
 * 用法:
 *   npx hardhat run scripts/addSettleAdminsToBUnitAirdrop.ts --network conet
 *   或
 *   npx tsx scripts/addSettleAdminsToBUnitAirdrop.ts
 *
 * 前置:
 *   - ~/.master.json 配置 settle_contractAdmin
 *   - settle_contractAdmin[0] 需为 BUnitAirdrop 的 owner（若 owner 已转移给 ConetTreasury 则无法执行）
 *   - 需有足够 CNET 支付 gas
 */

import { ethers } from 'ethers'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { readFileSync } from 'node:fs'
import Colors from 'colors/safe'

const CONET_RPC = 'https://rpc1.conet.network'
const ADDR_PATH = join(process.cwd(), 'deployments', 'conet-addresses.json')
function loadBUnitAirdropAddress(): string {
  try {
    const data = JSON.parse(readFileSync(ADDR_PATH, 'utf-8'))
    return data.BUnitAirdrop || '0xa7410a532544aB7d1bA70701D9D0E389e4f4Cc1F'
  } catch {
    return '0xa7410a532544aB7d1bA70701D9D0E389e4f4Cc1F'
  }
}
const BUNIT_AIRDROP_ABI = [
  'function owner() view returns (address)',
  'function admins(address) view returns (bool)',
  'function addAdmin(address account)',
] as const

const setupFile = join(homedir(), '.master.json')
let masterSetup: { settle_contractAdmin?: string[] }

try {
  masterSetup = JSON.parse(readFileSync(setupFile, 'utf-8'))
} catch (e) {
  console.error(Colors.red(`❌ 无法读取配置文件: ${setupFile}`))
  console.error(Colors.red(`错误: ${e instanceof Error ? e.message : String(e)}`))
  process.exit(1)
}

const adminPks = masterSetup?.settle_contractAdmin || []
if (!adminPks.length) {
  console.error(Colors.red('❌ ~/.master.json 中 settle_contractAdmin 为空或未设置'))
  process.exit(1)
}

async function main() {
  const provider = new ethers.JsonRpcProvider(CONET_RPC)
  const normalizedPks = adminPks.map((pk: string) => {
    const t = String(pk).trim()
    return t.startsWith('0x') ? t : `0x${t}`
  })
  const addresses = normalizedPks.map((pk: string) => new ethers.Wallet(pk).address)
  const signer = new ethers.Wallet(normalizedPks[0], provider)

  const BUNIT_AIRDROP_ADDRESS = loadBUnitAirdropAddress()
  const airdrop = new ethers.Contract(BUNIT_AIRDROP_ADDRESS, BUNIT_AIRDROP_ABI, provider)
  const owner = await airdrop.owner()

  console.log(Colors.cyan('='.repeat(60)))
  console.log(Colors.cyan('BUnitAirdrop Admin 登记检查'))
  console.log(Colors.cyan('='.repeat(60)))
  console.log('BUnitAirdrop:', BUNIT_AIRDROP_ADDRESS)
  console.log('Owner:', owner)
  console.log('Signer (settle_contractAdmin[0]):', signer.address)
  console.log('settle_contractAdmin 数量:', addresses.length)
  console.log()

  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    console.error(Colors.red('❌ Signer 不是 BUnitAirdrop owner，无法执行 addAdmin'))
    console.log(Colors.yellow('   addAdmin 仅 owner 可调用。若 owner 已转移给 ConetTreasury，需通过 ConetTreasury 治理添加。'))
    process.exit(1)
  }

  const toAdd: string[] = []
  for (const addr of addresses) {
    const isAdmin = await airdrop.admins(addr)
    if (!isAdmin) toAdd.push(addr)
    else console.log(Colors.gray(`  ✓ ${addr} 已是 admin`))
  }

  if (toAdd.length === 0) {
    console.log(Colors.green('✅ 所有 settle_contractAdmin 地址已登记为 BUnitAirdrop admin'))
    return
  }

  console.log(Colors.yellow(`\n待添加 ${toAdd.length} 个 admin:`))
  toAdd.forEach((a, i) => console.log(`  ${i + 1}. ${a}`))
  console.log()

  const airdropWithSigner = new ethers.Contract(loadBUnitAirdropAddress(), BUNIT_AIRDROP_ABI, signer)
  for (let i = 0; i < toAdd.length; i++) {
    const addr = toAdd[i]
    try {
      const tx = await airdropWithSigner.addAdmin(addr)
      console.log(Colors.cyan(`[${i + 1}/${toAdd.length}] addAdmin(${addr}) tx: ${tx.hash}`))
      await tx.wait()
      console.log(Colors.green(`  ✅ 已登记`))
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e)
      console.error(Colors.red(`  ❌ 失败: ${msg}`))
      process.exit(1)
    }
  }

  console.log()
  console.log(Colors.green('✅ 全部完成'))
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(Colors.red('未捕获错误:'), e)
    process.exit(1)
  })
