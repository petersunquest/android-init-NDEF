/**
 * 导出 BeamioBUnits UUPS 验证用 Standard JSON（递归剪枝，避免 Blockscout 413）。
 * 运行: npx tsx scripts/exportBeamioBUnitsUupsStandardJson.ts
 */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { exportBasescanStandardJsonFromRoot } from "./basescanStandardJsonShared.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const SOURCE_KEY = "project/src/b-unit/BUint.sol";
const CONTRACT_FILE = "project/src/b-unit/BUint.sol:BeamioBUnits";
const COMPILER_VERSION = "v0.8.35+commit.47b9dedd";

function main() {
  const { standardJson, sourceCount } = exportBasescanStandardJsonFromRoot(root, SOURCE_KEY);
  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const jsonPath = path.join(deploymentsDir, "base-BeamioBUnits-standard-input-FULL-FORM.json");
  fs.writeFileSync(jsonPath, JSON.stringify(standardJson, null, 2) + "\n", "utf-8");

  const metaPath = path.join(deploymentsDir, "base-BeamioBUnits-basescan-verify-meta.txt");
  fs.writeFileSync(
    metaPath,
    `BeamioBUnits UUPS implementation verification
Contract: ${CONTRACT_FILE}
Compiler: ${COMPILER_VERSION}
Sources: ${sourceCount}
Constructor Args ABI-encoded: (none — UUPS impl uses _disableInitializers only)
`,
    "utf-8"
  );

  console.log("✅", jsonPath, (fs.statSync(jsonPath).size / 1024).toFixed(1), "KB,", sourceCount, "sources");
}

main();
