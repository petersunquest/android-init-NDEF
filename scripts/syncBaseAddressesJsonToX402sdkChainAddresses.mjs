/**
 * 将 config/base-addresses.json 中的 Base 主网地址写入 src/x402sdk/src/chainAddresses.ts。
 * 同步字段（若 JSON 中存在且合法）：AA_FACTORY、BEAMIO_ACCOUNT_DEPLOYER、CARD_FACTORY、CCSA_CARD_ADDRESS、
 * BASE_TREASURY、BEAMIO_USER_CARD_ASSET_ADDRESS、PURCHASING_CARD_METADATA_ADDRESS、USDC_BASE、
 * BEAMIO_USER_CARD_FORMATTING_LIB、BEAMIO_USER_CARD_TRANSFER_LIB（BeamioUserCard 链接库）。
 *
 * 用法（BeamioContract 根目录）：
 *   node scripts/syncBaseAddressesJsonToX402sdkChainAddresses.mjs
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { getAddress } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const JSON_PATH = path.join(ROOT, "config", "base-addresses.json");
const CHAIN_TS = path.join(ROOT, "src", "x402sdk", "src", "chainAddresses.ts");

if (!fs.existsSync(JSON_PATH)) {
  console.error("Missing:", JSON_PATH);
  process.exit(1);
}
if (!fs.existsSync(CHAIN_TS)) {
  console.error("Missing:", CHAIN_TS);
  process.exit(1);
}

const base = JSON.parse(fs.readFileSync(JSON_PATH, "utf-8"));
const addrRe = /^0x[a-fA-F0-9]{40}$/;

function needAddr(label, v) {
  if (typeof v !== "string" || !addrRe.test(v)) {
    console.error(`config/base-addresses.json: invalid or missing ${label}`);
    process.exit(1);
  }
  return getAddress(v);
}

function maybeAddr(v) {
  if (typeof v !== "string" || !addrRe.test(v)) return null;
  return getAddress(v);
}

const aaChecksum = needAddr("AA_FACTORY", base.AA_FACTORY);

/** @type {Array<[string, keyof typeof base, RegExp]>} */
const OPTIONAL = [
  ["BASE_CARD_FACTORY", "CARD_FACTORY", /export const BASE_CARD_FACTORY = '0x[a-fA-F0-9]{40}'/],
  [
    "BASE_CCSA_CARD_ADDRESS",
    "CCSA_CARD_ADDRESS",
    /export const BASE_CCSA_CARD_ADDRESS = '0x[a-fA-F0-9]{40}'/,
  ],
  ["BASE_TREASURY", "BASE_TREASURY", /export const BASE_TREASURY = '0x[a-fA-F0-9]{40}'/],
  [
    "BEAMIO_USER_CARD_ASSET_ADDRESS",
    "BEAMIO_USER_CARD_ASSET_ADDRESS",
    /export const BEAMIO_USER_CARD_ASSET_ADDRESS = '0x[a-fA-F0-9]{40}'/,
  ],
  [
    "PURCHASING_CARD_METADATA_ADDRESS",
    "PURCHASING_CARD_METADATA_ADDRESS",
    /export const PURCHASING_CARD_METADATA_ADDRESS = '0x[a-fA-F0-9]{40}'/,
  ],
  ["USDC_BASE", "USDC_BASE", /export const USDC_BASE = '0x[a-fA-F0-9]{40}'/],
  [
    "BASE_BEAMIO_USER_CARD_FORMATTING_LIB",
    "BEAMIO_USER_CARD_FORMATTING_LIB",
    /export const BASE_BEAMIO_USER_CARD_FORMATTING_LIB = '[^']*'/,
  ],
  [
    "BASE_BEAMIO_USER_CARD_TRANSFER_LIB",
    "BEAMIO_USER_CARD_TRANSFER_LIB",
    /export const BASE_BEAMIO_USER_CARD_TRANSFER_LIB = '[^']*'/,
  ],
];

let ts = fs.readFileSync(CHAIN_TS, "utf-8");
const aaLineRe = /export const BASE_AA_FACTORY = '0x[a-fA-F0-9]{40}'/;
if (!aaLineRe.test(ts)) {
  console.error("chainAddresses.ts: could not find BASE_AA_FACTORY line to replace");
  process.exit(1);
}
ts = ts.replace(aaLineRe, `export const BASE_AA_FACTORY = '${aaChecksum}'`);

const depLineRe = /export const BASE_BEAMIO_ACCOUNT_DEPLOYER = '0x[a-fA-F0-9]{40}'/;
const depAddr = maybeAddr(base.BEAMIO_ACCOUNT_DEPLOYER);
if (depAddr && depLineRe.test(ts)) {
  ts = ts.replace(depLineRe, `export const BASE_BEAMIO_ACCOUNT_DEPLOYER = '${depAddr}'`);
}

for (const [exportName, jsonKey, lineRe] of OPTIONAL) {
  const v = maybeAddr(base[jsonKey]);
  if (!v) continue;
  if (!lineRe.test(ts)) {
    console.warn(`skip ${exportName}: line not found in chainAddresses.ts`);
    continue;
  }
  ts = ts.replace(lineRe, `export const ${exportName} = '${v}'`);
}

fs.writeFileSync(CHAIN_TS, ts, "utf-8");
console.log("Synced config/base-addresses.json -> src/x402sdk/src/chainAddresses.ts");
console.log("  BASE_AA_FACTORY:", aaChecksum);
