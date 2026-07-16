/**
 * Print the exact BaseScan Token Info values for the canonical bridge assets.
 *
 * BaseScan's logo/name/social metadata is an off-chain Token Info submission;
 * this script deliberately performs no network write.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const manifestPath = path.join(root, "deployments/assets/base/token-info.json");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as {
  chain: string;
  chainId: number;
  tokens: Array<{
    address: string;
    name: string;
    symbol: string;
    decimals: number;
    logoFile: string;
    iconUrl: string;
    explorer: string;
  }>;
};

console.log(`BaseScan Token Info (${manifest.chain}, chainId ${manifest.chainId})`);
console.log("Submit each token after implementation and proxy verification.");
console.log("Upload the matching 256px PNG; BaseScan does not read icon_url from ERC20 bytecode.");
for (const token of manifest.tokens) {
  console.log("\n" + token.symbol);
  console.log(`  address:   ${token.address}`);
  console.log(`  name:      ${token.name}`);
  console.log(`  symbol:    ${token.symbol}`);
  console.log(`  decimals:  ${token.decimals}`);
  console.log(`  logo file: ${token.logoFile}`);
  console.log(`  icon URL:  ${token.iconUrl}`);
  console.log(`  explorer:  ${token.explorer}`);
}
