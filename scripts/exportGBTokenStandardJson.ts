/**
 * 导出 GBToken 验证用 Standard JSON（递归剪枝，避免 CoNET scan 413）。
 * 运行: npx tsx scripts/exportGBTokenStandardJson.ts
 */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { AbiCoder } from "ethers";
import { exportBasescanStandardJsonFromRoot } from "./basescanStandardJsonShared.js";
import { GBTOKEN_CREATE2_PREDICTED, GBTOKEN_INITIAL_ADMIN } from "./gbTokenDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const SOURCE_KEY = "project/src/b-unit/GBToken.sol";
const CONTRACT_NAME = "GBToken";
const COMPILER_VERSION = "v0.8.35+commit.47b9dedd";

function main() {
  const { standardJson, sourceCount } = exportBasescanStandardJsonFromRoot(root, SOURCE_KEY);
  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const jsonPath = path.join(deploymentsDir, "base-GBToken-standard-input-FULL-FORM.json");
  fs.writeFileSync(jsonPath, JSON.stringify(standardJson, null, 2) + "\n", "utf-8");

  const constructorArgs = AbiCoder.defaultAbiCoder()
    .encode(["address"], [GBTOKEN_INITIAL_ADMIN])
    .slice(2);

  const metaPath = path.join(deploymentsDir, "base-GBToken-basescan-verify-meta.txt");
  fs.writeFileSync(
    metaPath,
    `GBToken verification
Address: ${GBTOKEN_CREATE2_PREDICTED}
Contract: ${SOURCE_KEY}:${CONTRACT_NAME}
Compiler: ${COMPILER_VERSION}
Sources: ${sourceCount}
Constructor Args ABI-encoded: ${constructorArgs}
`,
    "utf-8"
  );

  console.log("✅", jsonPath, (fs.statSync(jsonPath).size / 1024).toFixed(1), "KB,", sourceCount, "sources");
}

main();
