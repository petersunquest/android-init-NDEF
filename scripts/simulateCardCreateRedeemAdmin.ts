/**
 * 使用 CoNET Base RPC（base-rpc.conet.network）模拟 cardCreateRedeemAdmin 的 executeForOwner 调用。
 * 用于验证链上状态与 RPC 是否正常。
 *
 * 运行：npx tsx scripts/simulateCardCreateRedeemAdmin.ts
 */
import { ethers } from 'ethers'

const RPC = process.env.BASE_RPC_URL?.trim() || 'https://base-rpc.conet.network'
const FACTORY = '0xfB5E3F2AbFe24DC17970d78245BeF56aAE8cb71a'
const CARD = '0x48952F9EA1231b59e5c5FA1a99BC657B122CFDfD'

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC)
  console.log('RPC:', RPC)

  // 1. 检查 Factory defaultAdminStatsQueryModule
  const factory = new ethers.Contract(
    FACTORY,
    ['function defaultAdminStatsQueryModule() view returns (address)'],
    provider
  )
  const moduleAddr = await factory.defaultAdminStatsQueryModule()
  console.log('Factory defaultAdminStatsQueryModule:', moduleAddr)

  // 2. 检查 module 是否识别 createRedeemAdmin
  const createRedeemAdminSel = ethers.id('createRedeemAdmin(bytes32,string,uint64,uint64,uint256)').slice(0, 10) as `0x${string}`
  const module = new ethers.Contract(
    moduleAddr,
    ['function selectorModuleKind(bytes4) view returns (uint8)'],
    provider
  )
  const kind = Number(await module.selectorModuleKind(createRedeemAdminSel))
  console.log('selectorModuleKind(createRedeemAdmin):', kind, kind === 0 ? 'OK (ROUTE_REDEEM)' : 'FAIL')

  // 2b. 模拟卡获取的 statsModule（卡通过 factoryGateway().defaultAdminStatsQueryModule() 获取）
  const cardGateway = new ethers.Contract(
    CARD,
    ['function factoryGateway() view returns (address)'],
    provider
  )
  const cardGw = await cardGateway.factoryGateway()
  console.log('Card factoryGateway():', cardGw)
  const gwModule = new ethers.Contract(
    cardGw,
    ['function defaultAdminStatsQueryModule() view returns (address)'],
    provider
  )
  const cardStatsModule = await gwModule.defaultAdminStatsQueryModule()
  console.log('Card would get statsModule:', cardStatsModule)
  if (cardStatsModule.toLowerCase() !== moduleAddr.toLowerCase()) {
    console.log('⚠️  Card uses different module than Factory!')
  }

  // 3. 构造与失败日志相同的 calldata 并 eth_call 模拟
  const txData =
    '0xc1cfc34a00000000000000000000000048952f9ea1231b59e5c5fa1a99bc657b122cfdfd00000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000069b61ca38b3010a6d4a873aa8334aff5a4124974e20e89e720cb1a1f02cbd4771faaf6430000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000012415e99acc5a6ff1c08cef9cee78aee0ea55c4693ae837b2be7837f0c3882bafc49898c5db00000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000069b61b3b000000000000000000000000000000000000000000000000000000006b974ef7000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000000000000000004b7b2272657374617572616e744e616d65223a227465737432222c2263756973696e65223a227465737432222c226369747941726561223a227465737432222c2268616e646c65223a22227d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000041a03093d1dadd62039dcaeaad386208eb3866464a34b85add45266a42261fcd8e7765b0c1e1c7d96fee82db4519842d7d8d547a116f8e90699cb40b30c4a291711b00000000000000000000000000000000000000000000000000000000000000'

  const fromAddr = '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
  // 3a. 直接调用卡（应失败 UC_UnauthorizedGateway 或 BM_CallFailed）
  const idx = txData.indexOf('15e99acc')
  const createRedeemAdminLen = 0x124 * 2 // 292 bytes in hex chars
  const fullInnerData = '0x' + txData.slice(idx, idx + createRedeemAdminLen)
  console.log('\n3a. Direct call to card (expect UC_UnauthorizedGateway if routing works)...')
  try {
    await provider.call({
      from: fromAddr as `0x${string}`,
      to: CARD as `0x${string}`,
      data: fullInnerData as `0x${string}`,
    })
    console.log('   Unexpected: direct call succeeded')
  } catch (e: any) {
    const data = (e?.data ?? e?.info?.error?.data ?? e?.error?.data) as string
    console.log('   Revert:', data?.slice(0, 10) || e?.shortMessage)
    if (data === '0x36550849') console.log('   -> BM_CallFailed: routing failed (selectorModuleKind returned ROUTE_INVALID)')
    else if (data?.startsWith('0x')) console.log('   -> Different error: routing may work, check modifier')
  }

  // 3b. 通过 Factory 模拟
  console.log('\n3b. Simulating via Factory executeForOwner...')
  try {
    await provider.call({
      from: fromAddr as `0x${string}`,
      to: FACTORY as `0x${string}`,
      data: txData as `0x${string}`,
    })
    console.log('✅ eth_call succeeded')
  } catch (e: any) {
    console.log('❌ eth_call failed:', e?.shortMessage ?? e?.message)
    const data = e?.data ?? e?.info?.error?.data ?? e?.error?.data
    if (data) console.log('   Revert data:', data)
  }
}

main().catch(console.error)
