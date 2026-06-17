/**
 * CoNET Explorer 验证 BusinessStartKetRedeem
 *
 * hardhat verify blockscout 全量 solc input 会触发 Blockscout 413；
 * 本脚本委托剪枝 Standard JSON 流程（verifyBusinessStartKetStackOnScan.ts）。
 *
 * 运行:
 *   npx tsx scripts/verifyBusinessStartKetRedeemConet.ts
 *   npx hardhat run scripts/verifyBusinessStartKetRedeemConet.ts --network conet
 */

import { execSync } from "child_process";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

execSync("npx tsx scripts/verifyBusinessStartKetStackOnScan.ts BusinessStartKetRedeem", {
  stdio: "inherit",
  cwd: root,
});
