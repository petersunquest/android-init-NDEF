#!/usr/bin/env node
/**
 * 导出 CoNET LayerMinusNodeRestart_V2 验证用最小 Solidity Standard JSON Input。
 *
 * 前置: npm run compile
 *
 * 用法:
 *   node scripts/exportLayerMinusNodeRestartV2ConetStandardJson.mjs
 *
 * 输出: deployments/conet-LayerMinusNodeRestart_V2-standard-input.json
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const sourceKey = "project/src/mainnet/LayerMinusNodeRestart_V2.sol";

const buildInfoDir = path.join(root, "artifacts", "build-info");
const files = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));

let buildInfoPath = null;
for (const f of files) {
  const p = path.join(buildInfoDir, f);
  try {
    const j = JSON.parse(fs.readFileSync(p, "utf-8"));
    if (j.input?.sources?.[sourceKey]) {
      buildInfoPath = p;
      break;
    }
  } catch {
    /* skip */
  }
}

if (!buildInfoPath) {
  console.error("未找到含 LayerMinusNodeRestart_V2 的 build-info，请先: npm run compile");
  process.exit(1);
}

const bi = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
const input = {
  language: bi.input.language,
  settings: bi.input.settings,
  sources: { [sourceKey]: bi.input.sources[sourceKey] },
};

const outPath = path.join(root, "deployments", "conet-LayerMinusNodeRestart_V2-standard-input.json");
fs.writeFileSync(outPath, JSON.stringify(input, null, 2) + "\n", "utf-8");
console.log("使用 build-info:", path.basename(buildInfoPath));
console.log("已写入:", outPath);
console.log("大小:", (fs.statSync(outPath).size / 1024).toFixed(1), "KB");
console.log("Explorer 合约名（contract_name）: LayerMinusNodeRestart_V2");
