'use strict'
const fs = require('fs')
const path = require('path')
const { ethers } = require('ethers')

const ROOT = '/Users/peter/Downloads/BeamioContract'
const SDK_FILE = path.join(ROOT, 'src/x402sdk/src/endpoint/validatorDepositRedeem.ts')
const ARTIFACT = path.join(ROOT, 'artifacts/src/mainnet/ValidatorDepositRedeem.sol/ValidatorDepositRedeem.json')
const PROXY = '0xc71e246DD78B37C2fABc905D340932F28F503433'
const RPC = 'https://mainnet.conet.network'

function selectorOf(fragment) {
  try {
    const f = ethers.FunctionFragment.from(fragment)
    return { name: f.name, sig: f.format('sighash'), selector: ethers.id(f.format('sighash')).slice(0, 10) }
  } catch (e) {
    return { name: '(parse-fail)', sig: String(fragment).slice(0, 80), selector: null, err: e.shortMessage || e.message }
  }
}

;(async () => {
  const sdkText = fs.readFileSync(SDK_FILE, 'utf8')

  // 1) SDK ABI function strings: lines like 'function xxx(...)' inside the ABI array
  const abiLineRe = /'(function [^']+)'/g
  const sdkAbiFns = []
  let m
  while ((m = abiLineRe.exec(sdkText))) sdkAbiFns.push(m[1])

  // 2) SDK actual contract method calls: <ident>.<method>!(   (capture method)
  const callRe = /\.([a-zA-Z_][a-zA-Z0-9_]*)!\s*\(/g
  const callCounts = {}
  while ((m = callRe.exec(sdkText))) {
    callCounts[m[1]] = (callCounts[m[1]] || 0) + 1
  }

  // 3) authoritative artifact ABI
  const artifact = JSON.parse(fs.readFileSync(ARTIFACT, 'utf8'))
  const artFns = artifact.abi.filter((x) => x.type === 'function')
  const artBySelector = new Map()
  const artByName = new Map()
  for (const fn of artFns) {
    const sig = `${fn.name}(${fn.inputs.map((i) => i.type).join(',')})`
    const sel = ethers.id(sig).slice(0, 10)
    artBySelector.set(sel, { name: fn.name, sig, view: fn.stateMutability === 'view' || fn.stateMutability === 'pure', outputs: (fn.outputs || []).map((o) => o.type).join(',') })
    if (!artByName.has(fn.name)) artByName.set(fn.name, [])
    artByName.get(fn.name).push({ sig, sel, view: fn.stateMutability === 'view' || fn.stateMutability === 'pure', outputs: (fn.outputs || []).map((o) => o.type).join(',') })
  }

  // 4) on-chain impl code (fault-tolerant: artifact comparison still runs if RPC fails)
  let impl = '(rpc-unavailable)'
  let code = ''
  let rpcOk = false
  try {
    const p = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true })
    const slot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
    const raw = await p.getStorage(PROXY, slot)
    impl = ethers.getAddress('0x' + raw.slice(26))
    code = await p.getCode(impl)
    rpcOk = true
  } catch (e) {
    console.log('[warn] RPC unavailable, skipping on-chain selector check:', e.shortMessage || e.message)
  }
  const inCode = (sel) => (rpcOk && sel ? code.includes(sel.slice(2)) : null)

  // compare artifact deployedBytecode vs on-chain (sanity)
  const artDeployed = (artifact.deployedBytecode || '').toLowerCase()
  const onchain = code.toLowerCase()
  let bytecodeMatch = rpcOk ? 'n/a' : 'rpc-skip'
  if (rpcOk && artDeployed && artDeployed.length > 4) {
    bytecodeMatch = artDeployed === onchain ? 'EXACT' : (onchain.length === artDeployed.length ? 'same-len-diff(immutables?)' : 'DIFFERENT-LEN')
  }

  console.log('================ VALIDATOR DEPOSIT REDEEM — SDK vs CONTRACT AUDIT ================')
  console.log('proxy        :', PROXY)
  console.log('implementation:', impl)
  console.log('artifact deployedBytecode vs on-chain:', bytecodeMatch)
  console.log('SDK ABI fn count:', sdkAbiFns.length, '| artifact fn count:', artFns.length)
  console.log('')

  // --- A) SDK ABI fragments: selector existence on-chain + matches artifact ---
  console.log('=== [A] SDK ABI fragments — on-chain & artifact check ===')
  const abiProblems = []
  for (const fn of sdkAbiFns) {
    const s = selectorOf(fn)
    const onc = inCode(s.selector)
    const inArt = s.selector && artBySelector.has(s.selector)
    // ground truth = artifact (current source). on-chain when available.
    const okByArtifact = inArt
    const status = okByArtifact ? (onc === false ? 'ARTIFACT-OK/ONCHAIN-MISSING' : 'OK') : 'MISMATCH'
    if (!okByArtifact) {
      const sameName = artByName.has(s.name) ? artByName.get(s.name).map((x) => x.sig) : null
      abiProblems.push({ sdk: s.sig, selector: s.selector, sameNameInArtifact: sameName })
    }
    const oncTag = onc === null ? 'rpc?' : (onc ? 'on:yes' : 'on:NO')
    console.log(`${status.padEnd(28)} art:${inArt ? 'yes' : 'NO '} ${oncTag.padEnd(7)} ${s.selector || '----------'} ${s.sig}${s.err ? '  [parse:' + s.err + ']' : ''}`)
  }
  console.log('')

  // --- B) SDK actual calls: name must exist in artifact functions ---
  console.log('=== [B] SDK contract method calls (c.xxx!()) — name exists in contract? ===')
  const callProblems = []
  for (const name of Object.keys(callCounts).sort()) {
    const exists = artByName.has(name)
    // only care about ones that look like contract methods present in SDK ABI too, but report all
    const inSdkAbi = sdkAbiFns.some((f) => f.startsWith('function ' + name + '('))
    const tag = exists ? 'OK' : 'NOT-IN-CONTRACT'
    if (!exists && inSdkAbi) {
      callProblems.push({ call: name, count: callCounts[name] })
    }
    console.log(`${tag.padEnd(16)} x${callCounts[name]}  ${name}${inSdkAbi ? '' : '   (not in SDK ABI either — maybe non-contract)'}`)
  }
  console.log('')

  // --- C) Artifact functions the SDK ABI is MISSING (selector not declared in SDK) ---
  console.log('=== [C] Contract functions NOT present in SDK ABI (by selector) ===')
  const sdkSelectors = new Set(sdkAbiFns.map((f) => selectorOf(f).selector).filter(Boolean))
  for (const [sel, info] of artBySelector) {
    if (!sdkSelectors.has(sel)) {
      console.log(`${sel} ${info.view ? '[view] ' : '       '}${info.sig}${info.outputs ? ' -> (' + info.outputs + ')' : ''}`)
    }
  }
  console.log('')

  console.log('================ SUMMARY ================')
  console.log('ABI fragments MISSING on-chain:', abiProblems.length)
  for (const x of abiProblems) console.log('  - SDK ABI:', x.sig, '\n      contract same-name sigs:', x.sameNameInArtifact ? JSON.stringify(x.sameNameInArtifact) : '(no function with this name in contract)')
  console.log('Method calls NOT in contract:', callProblems.length)
  for (const x of callProblems) console.log('  - c.' + x.call + '()  x' + x.count)
})().catch((e) => console.error('FATAL', e))
