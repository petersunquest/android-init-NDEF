/**
 * 导出 FactoryERC20Upgradeable UUPS impl 验证用 Standard JSON。
 * 运行: npm run clean && npm run compile && npx tsx scripts/exportConetUsdcUupsStandardJson.ts
 */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { exportBasescanStandardJsonFromRoot } from "./basescanStandardJsonShared.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const SOURCE_KEY = "project/src/b-unit/FactoryERC20Upgradeable.sol";
const CONTRACT_FILE = "project/src/b-unit/FactoryERC20Upgradeable.sol:FactoryERC20Upgradeable";
const COMPILER_VERSION = "v0.8.35+commit.47b9dedd";

function main() {
  const { standardJson, sourceCount } = exportBasescanStandardJsonFromRoot(root, SOURCE_KEY);
  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const jsonPath = path.join(deploymentsDir, "base-FactoryERC20Upgradeable-standard-input-FULL-FORM.json");
  fs.writeFileSync(jsonPath, JSON.stringify(standardJson, null, 2) + "\n", "utf-8");

  const metaPath = path.join(deploymentsDir, "conet-FactoryERC20Upgradeable-basescan-verify-meta.txt");
  fs.writeFileSync(
    metaPath,
    `FactoryERC20Upgradeable UUPS implementation verification
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
