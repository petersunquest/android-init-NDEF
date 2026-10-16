/**
 * Close miner voteBridgeOperation on TreasuryBridgeV3 (Base + CoNET).
 * Owner auth: USDC deposits through this path may stop.
 *
 * Appends voteBridgeClosed into the spare bytes of slot 21 (after developerFxIssuer)
 * and upgradeToAndCall(setVoteBridgeClosed(true)).
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ROOT = join(__dirname, '..')
const { Contract, ContractFactory, JsonRpcProvider, Wallet, id } = createRequire(
  join(ROOT, 'package.json'),
)('ethers')

const PROXY = '0xa208982212978550594A7FEEB70a61665d129003'
const OWNER = '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
const ISSUER = '0x083da39C81D9078fE5d31e852eBAdb34B885b698'
const CLOSED_SELECTOR = id('VoteBridgeClosed()').slice(0, 10)
const CHAINS = [
  { name: 'conet', url: process.env.CONET_RPC_URL || 'https://rpc1.conet.network', chainId: 224422 },
  { name: 'base', url: process.env.BASE_RPC_URL || 'https://base-rpc.conet.network', chainId: 8453 },
]

function loadOwnerKey() {
  const raw = JSON.parse(readFileSync(join(homedir(), '.master.json'), 'utf8'))
  const candidates = []
  if (Array.isArray(raw.settle_contractAdmin)) candidates.push(...raw.settle_contractAdmin)
  if (Array.isArray(raw.beamio_Admins)) candidates.push(...raw.beamio_Admins)
  for (const key of candidates) {
    if (typeof key === 'string' && /^[0-9a-fA-F]{64}$/.test(key)) return `0x${key}`
  }
  throw new Error('no 64-hex admin key in ~/.master.json')
}

function artifact() {
  const path = join(ROOT, 'artifacts/src/b-unit/TreasuryBridgeV3.sol/TreasuryBridgeV3.json')
  const json = JSON.parse(readFileSync(path, 'utf8'))
  const bytecode = typeof json.bytecode === 'string' ? json.bytecode : json.bytecode.object
  const deployed =
    typeof json.deployedBytecode === 'string' ? json.deployedBytecode : json.deployedBytecode.object
  const bytes = deployed.length / 2
  if (bytes > 24576) throw new Error(`runtime ${bytes} exceeds 24576`)
  return { abi: json.abi, bytecode, deployedBytes: bytes }
}

async function closedCall(provider) {
  const data = new Contract(PROXY, artifact().abi, provider).interface.encodeFunctionData(
    'voteBridgeOperation',
    [
      '0x' + '11'.repeat(32),
      1n,
      8453n,
      PROXY,
      '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
      '0x5209865D404aA5646eDe5B91CD4218909eA72eDA',
      [OWNER],
      [1n],
      1,
      1n,
      0n,
      '0x' + '22'.repeat(32),
      1n,
      '0x0000000000000000000000000000000000000000',
    ],
  )
  try {
    await provider.call({ to: PROXY, from: OWNER, data })
    return 'did-not-revert'
  } catch (error) {
    const blob = `${error?.data || ''} ${error?.info?.error?.data || ''} ${error?.message || ''}`
    return blob.toLowerCase().includes(CLOSED_SELECTOR.slice(2)) ? 'VoteBridgeClosed' : `revert:${blob.slice(0, 180)}`
  }
}

async function main() {
  const art = artifact()
  const key = loadOwnerKey()
  const report = { runtimeBytes: art.deployedBytes, chains: {} }
  console.log(`runtime ${art.deployedBytes} bytes; closed selector ${CLOSED_SELECTOR}`)

  for (const chain of CHAINS) {
    const provider = new JsonRpcProvider(chain.url, chain.chainId)
    const wallet = new Wallet(key, provider)
    const signer = await wallet.getAddress()
    if (signer.toLowerCase() !== OWNER.toLowerCase()) {
      throw new Error(`${chain.name} key address ${signer} is not owner ${OWNER}`)
    }
    const proxy = new Contract(
      PROXY,
      [
        'function owner() view returns (address)',
        'function minerCount() view returns (uint256)',
        'function developerFxIssuer() view returns (address)',
        'function feeSettlement() view returns (address)',
        'function voteBridgeClosed() view returns (bool)',
        'function upgradeToAndCall(address newImplementation, bytes data)',
      ],
      wallet,
    )
    const owner = await proxy.owner()
    if (owner.toLowerCase() !== OWNER.toLowerCase()) {
      throw new Error(`${chain.name} owner ${owner}`)
    }
    const before = {
      minerCount: (await proxy.minerCount()).toString(),
      feeSettlement: await proxy.feeSettlement().catch(() => null),
      developerFxIssuer: await proxy.developerFxIssuer().catch(() => null),
    }
    let already = false
    try {
      already = await proxy.voteBridgeClosed()
    } catch {
      already = false
    }
    console.log(`${chain.name} before`, before, 'closed', already, 'balance', (await provider.getBalance(OWNER)).toString())
    if (already) {
      report.chains[chain.name] = { skipped: true, voteProbe: await closedCall(provider), ...before }
      continue
    }

    const factory = new ContractFactory(art.abi, art.bytecode, wallet)
    const impl = await factory.deploy()
    const implTx = impl.deploymentTransaction()
    const implRcpt = await implTx.wait()
    const implAddr = await impl.getAddress()
    console.log(`${chain.name} impl ${implAddr} tx ${implRcpt.hash} block ${implRcpt.blockNumber}`)

    const data = impl.interface.encodeFunctionData('setVoteBridgeClosed', [true])
    const up = await proxy.upgradeToAndCall(implAddr, data)
    const upRcpt = await up.wait()
    const closed = await proxy.voteBridgeClosed()
    const after = {
      minerCount: (await proxy.minerCount()).toString(),
      feeSettlement: await proxy.feeSettlement(),
      developerFxIssuer: await proxy.developerFxIssuer(),
    }
    if (!closed) throw new Error(`${chain.name} voteBridgeClosed is still false`)
    if (after.minerCount !== before.minerCount) throw new Error(`${chain.name} minerCount changed`)
    if (chain.name === 'conet' && after.developerFxIssuer.toLowerCase() !== ISSUER.toLowerCase()) {
      throw new Error(`conet developerFxIssuer changed to ${after.developerFxIssuer}`)
    }
    const voteProbe = await closedCall(provider)
    console.log(`${chain.name} upgrade ${upRcpt.hash} closed=${closed} vote=${voteProbe}`)
    report.chains[chain.name] = {
      impl: implAddr,
      deployTx: implRcpt.hash,
      deployBlock: implRcpt.blockNumber,
      upgradeTx: upRcpt.hash,
      upgradeBlock: upRcpt.blockNumber,
      voteBridgeClosed: closed,
      voteProbe,
      before,
      after,
    }
  }

  const out = join(ROOT, 'deployments/close-vote-bridge-operation.json')
  writeFileSync(out, JSON.stringify(report, null, 2) + '\n')
  console.log('wrote', out)
}

main().catch((error) => {
  console.error(error?.shortMessage || error?.message || error)
  process.exit(1)
})
