/**
 * Retry on-chain registerNodeValidators for succeeded redeem claims that never ran register-validators.
 *
 * Run on validator host (Settle pool in ~/.master.json):
 *   cd /home/peter/x402sdk && node ../BeamioContract/scripts/retryRegisterDeployedValidatorsConet.mjs
 */

import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const sdkRoot = process.env.X402SDK_ROOT?.trim() || path.join(__dirname, "../src/x402sdk");

async function main() {
  const mod = await import(path.join(sdkRoot, "dist/endpoint/validatorDepositRedeem.js"));
  const results = await mod.retryRegisterDeployedValidatorsForRedeemState();
  if (!results.length) {
    console.log("No redeem state entries to retry.");
    return;
  }
  for (const r of results) {
    console.log(`${r.ok ? "OK" : "FAIL"} ${r.requestId.slice(0, 18)}… — ${r.detail}`);
  }
  if (results.some((r) => !r.ok)) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
