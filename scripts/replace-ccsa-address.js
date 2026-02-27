#!/usr/bin/env node
/**
 * 将代码库中 CCSA 卡地址替换为新地址。
 * 用法：
 *   NEW_CCSA_ADDRESS=0x... node scripts/replace-ccsa-address.js
 *   或
 *   node scripts/replace-ccsa-address.js 0x新地址
 *
 * 可选 OLD_CCSA_ADDRESS 指定旧地址，否则自动从 chainAddresses 提取当前值并替换。
 *
 * 新地址需先通过 createCCSA 发行：
 *   CARD_OWNER=0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61 npm run create:ccsa:base
 *
 * 更新的文件：x402sdk/chainAddresses、SilentPassUI/config、deployments JSON。
 */
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, '..')
const ADDR_REGEX = /0x[a-fA-F0-9]{40}/

const FILES = [
  { path: 'src/x402sdk/src/chainAddresses.ts', pattern: /BASE_CCSA_CARD_ADDRESS\s*=\s*'0x[a-fA-F0-9]{40}'/ },
  { path: 'src/SilentPassUI/src/config/chainAddresses.ts', pattern: /BeamioCardCCSA_ADDRESS:\s*'0x[a-fA-F0-9]{40}'/, alsoUpdateOld: true },
  { path: 'deployments/base-UserCard-0xEaBF0A98.json', pattern: /"userCard"\s*:\s*"0x[a-fA-F0-9]{40}"/ },
]

function main() {
  const newAddr = (process.env.NEW_CCSA_ADDRESS || process.argv[2] || '').trim()
  if (!newAddr || !/^0x[a-fA-F0-9]{40}$/.test(newAddr)) {
    console.error('Usage: NEW_CCSA_ADDRESS=0x... node scripts/replace-ccsa-address.js')
    console.error('   or: node scripts/replace-ccsa-address.js 0x<new-address>')
    process.exit(1)
  }

  const oldAddr = process.env.OLD_CCSA_ADDRESS || null
  let replaced = 0

  for (const { path: rel, pattern, alsoUpdateOld } of FILES) {
    const file = path.join(ROOT, rel)
    if (!fs.existsSync(file)) {
      console.warn('Skip (not found):', rel)
      continue
    }
    let content = fs.readFileSync(file, 'utf8')

    if (pattern) {
      const match = content.match(pattern)
      if (match) {
        const current = match[0].match(ADDR_REGEX)[0]
        if (oldAddr && current.toLowerCase() !== oldAddr.toLowerCase()) {
          console.warn('Skip (current addr differs from OLD_CCSA_ADDRESS):', rel)
          continue
        }
        content = content.replace(pattern, match[0].replace(current, newAddr))
        if (alsoUpdateOld && rel.includes('chainAddresses')) {
          const oldPattern = /OLD_CCSA_CARD_ADDRESS:\s*'0x[a-fA-F0-9]{40}'/
          const oldMatch = content.match(oldPattern)
          if (oldMatch) {
            content = content.replace(oldPattern, `OLD_CCSA_CARD_ADDRESS: '${current}'`)
            console.log('Updated OLD_CCSA_CARD_ADDRESS ->', current)
          }
        }
        fs.writeFileSync(file, content)
        console.log('Updated:', rel, current, '->', newAddr)
        replaced++
      } else {
        console.log('No match:', rel)
      }
    } else {
      const m = content.match(ADDR_REGEX)
      if (m && (oldAddr ? m[0].toLowerCase() === oldAddr.toLowerCase() : true)) {
        content = content.replace(m[0], newAddr)
        fs.writeFileSync(file, content)
        console.log('Updated:', rel)
        replaced++
      }
    }
  }
  console.log('Done. Updated', replaced, 'file(s) with', newAddr)
}

main()
