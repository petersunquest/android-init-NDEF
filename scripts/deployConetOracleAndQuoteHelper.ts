/**
 * CoNET 部署 BeamioOracle + BeamioQuoteHelperV07（Nick CREATE2 同址栈）。
 * 已废弃直接 `new BeamioOracle()`；请使用 deployBeamioOracleStackCreate2.ts。
 *
 * 运行:
 *   CONET_RPC_URL=https://publicrpc.conet.network npx hardhat run scripts/deployConetOracleAndQuoteHelper.ts --network conet
 */
import { execSync } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");

console.log("→ 转发至 deployBeamioOracleStackCreate2.ts（CREATE2 同址）");
execSync("npx hardhat run scripts/deployBeamioOracleStackCreate2.ts --network conet", {
  cwd: ROOT,
  stdio: "inherit",
  env: process.env,
});
