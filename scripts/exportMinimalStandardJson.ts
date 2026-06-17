/**
 * 从当前文件系统递归导出某个 Solidity 根文件的 BaseScan Standard JSON Input。
 * 对齐 exportBeamioUserCardBasescanStandardJson.ts / BeamioUserCard 成功验证路径。
 *
 * 用法:
 *   npx tsx scripts/exportMinimalStandardJson.ts \
 *     --root project/src/b-unit/conetTreasury.sol \
 *     --out deployments/base-ConetTreasury-basescan-standard-input.json
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { exportBasescanStandardJsonFromRoot } from "./basescanStandardJsonShared.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.join(__dirname, "..");

const args = process.argv.slice(2);

function getArg(name: string): string {
  const idx = args.indexOf(name);
  if (idx === -1 || idx + 1 >= args.length) {
    throw new Error(`缺少参数 ${name}`);
  }
  return args[idx + 1];
}

function main() {
  const rootSource = getArg("--root");
  const outPath = path.resolve(process.cwd(), getArg("--out"));
  const { standardJson, sourceCount } = exportBasescanStandardJsonFromRoot(ROOT_DIR, rootSource);

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(standardJson, null, 2), "utf-8");
  console.log(`已导出 ${sourceCount} 个源码文件到: ${outPath}`);
  console.log(`source root: ${rootSource}`);
  console.log(`size KB: ${(fs.statSync(outPath).size / 1024).toFixed(1)}`);
}

main();
