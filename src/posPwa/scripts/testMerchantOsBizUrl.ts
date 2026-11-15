/**
 * Offline check: the Merchant OS entry uses beamio.ca and never the legacy biz.beamio.app host.
 * Run: node --experimental-strip-types scripts/testMerchantOsBizUrl.ts
 */
import assert from 'node:assert/strict'
import { MERCHANT_OS_BIZ_URL } from '../src/utils/merchantOsBizUrl.ts'

const u = new URL(MERCHANT_OS_BIZ_URL)
assert.equal(u.protocol, 'https:')
assert.equal(u.host, 'biz.beamio.ca')
assert.equal(u.pathname, '/biz/')
assert.ok(!MERCHANT_OS_BIZ_URL.includes('beamio.app'), 'legacy host must not appear')
console.log('ok', MERCHANT_OS_BIZ_URL)
console.log('ALL PASS')
