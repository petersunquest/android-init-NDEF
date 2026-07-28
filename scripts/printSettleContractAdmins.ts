/**
 * 打印 masterSetup.settle_contractAdmin 的所有钱包地址及 Conet 链上原生代币余额
 * 用法: npx ts-node scripts/printSettleContractAdmins.ts
 */
import { join } from 'node:path'
import { homedir } from 'node:os'
import { readFileSync } from 'node:fs'
import { ethers } from 'ethers'

const CONET_RPC = 'https://rpc1.conet.network'
const providerConet = new ethers.JsonRpcProvider(CONET_RPC)

const setupFile = join(homedir(), '.master.json')
const masterSetup: { settle_contractAdmin?: string[] } = JSON.parse(readFileSync(setupFile, 'utf-8'))

if (!masterSetup?.settle_contractAdmin?.length) {
  console.error('~/.master.json 中 settle_contractAdmin 为空或不存在')
  process.exit(1)
}

console.log(`settle_contractAdmin 共 ${masterSetup.settle_contractAdmin.length} 个钱包 (Conet 链原生代币):\n`)

async function main() {
  for (let i = 0; i < masterSetup.settle_contractAdmin!.length; i++) {
    const pk = masterSetup.settle_contractAdmin![i]
    const wallet = new ethers.Wallet(pk)
    const balance = await providerConet.getBalance(wallet.address)
    const balanceNum = Number(ethers.formatEther(balance))
    const display = balanceNum >= 1
      ? balanceNum.toFixed(4)
      : balanceNum >= 0.0001
        ? balanceNum.toFixed(6)
        : balanceNum > 0
          ? balanceNum.toFixed(18).replace(/\.?0+$/, '')
          : '0'
    console.log(`${i + 1}. ${wallet.address}  CNET: ${display}`)
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
