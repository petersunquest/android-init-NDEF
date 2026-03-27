/**
 * 使用与 conet-si 相同的 RPC 配置（~/.master.json base_endpoint）检查链上 AdminStatsQueryModule。
 * 在 conet-si 服务器上运行此脚本，可验证服务器看到的链状态是否与部署一致。
 *
 * 运行：npx tsx scripts/checkAdminStatsQueryModuleFromMasterJson.ts
 * 或：node --loader ts-node/esm scripts/checkAdminStatsQueryModuleFromMasterJson.ts
 */
import { join } from 'node:path'
import { homedir } from 'node:os'
import { readFileSync } from 'node:fs'
import { ethers } from 'ethers'

const FACTORY = '0x2EB245646de404b2Dce87E01C6282C131778bb05'
const ROUTE_REDEEM = 0
const ROUTE_INVALID = 255

function loadMasterSetup(): { base_endpoint?: string } {
  const setupPath = join(homedir(), '.master.json')
  try {
    const raw = readFileSync(setupPath, 'utf-8')
    return JSON.parse(raw) ?? {}
  } catch {
    return {}
  }
}

async function main() {
  const master = loadMasterSetup()
  const baseRpc = master?.base_endpoint || 'https://base-rpc.conet.network'
  console.log('Using RPC (from ~/.master.json base_endpoint or default):', baseRpc)

  const provider = new ethers.JsonRpcProvider(baseRpc)
  const createRedeemAdmin5Selector = ethers.id('createRedeemAdmin(bytes32,string,uint64,uint64,uint256)').slice(0, 10) as `0x${string}`

  const factory = new ethers.Contract(
    FACTORY,
    ['function defaultAdminStatsQueryModule() view returns (address)'],
    provider
  )
  const moduleAddr = (await factory.defaultAdminStatsQueryModule()) as string
  console.log('Factory defaultAdminStatsQueryModule:', moduleAddr)

  const expectedModule = '0x59e54Af96BeEB36C13753170DF0a9Bb7b0123438'
  if (moduleAddr.toLowerCase() !== expectedModule.toLowerCase()) {
    console.log('⚠️  Expected (after deploy):', expectedModule)
    console.log('   Server sees different module - RPC may be stale or pointing to different chain')
  }

  const module = new ethers.Contract(
    moduleAddr,
    ['function selectorModuleKind(bytes4) view returns (uint8)'],
    provider
  )
  const kind = Number(await module.selectorModuleKind(createRedeemAdmin5Selector))
  console.log('selectorModuleKind(createRedeemAdmin):', kind, kind === ROUTE_REDEEM ? 'OK' : kind === ROUTE_INVALID ? 'FAIL' : 'UNEXPECTED')

  if (kind === ROUTE_INVALID) {
    console.log('\n❌ Server RPC sees AdminStatsQueryModule that does NOT recognize createRedeemAdmin.')
    console.log('   Fix: Set base_endpoint in ~/.master.json to https://base-rpc.conet.network and restart conet-si')
    process.exit(1)
  }
  console.log('\n✅ Server RPC sees correct AdminStatsQueryModule.')
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
