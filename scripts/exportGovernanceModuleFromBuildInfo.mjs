#!/usr/bin/env node
/**
 * 从 build-info 提取 GovernanceModule 的 Standard JSON（与 Hardhat 编译输入完全一致）
 * 用于 BaseScan 验证，确保 bytecode 匹配
 *
 * 运行: node scripts/exportGovernanceModuleFromBuildInfo.mjs
 * 可选: node scripts/exportGovernanceModuleFromBuildInfo.mjs --full
 *       --full 使用完整 build-info 输入（via-IR 下跨编译单元优化可能影响输出）
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BUILD_INFO = path.join(__dirname, "../artifacts/build-info/solc-0_8_33-5661d6a963e5f2fe15c674daf45a29c499dbcebc.json");
const OUT_MIN = path.join(__dirname, "../deployments/base-GovernanceModule-standard-input.min.json");
const OUT_FULL = path.join(__dirname, "../deployments/base-GovernanceModule-standard-input-FULL.json");

const GOV_DEPS = [
  "project/src/BeamioUserCard/GovernanceModule.sol",
  "project/src/BeamioUserCard/Errors.sol",
  "project/src/BeamioUserCard/GovernanceStorage.sol",
  "project/src/BeamioUserCard/AdminStatsStorage.sol",
];

const useFull = process.argv.includes("--full");

const buildInfo = JSON.parse(fs.readFileSync(BUILD_INFO, "utf-8"));
const fullInput = buildInfo.input;

let input;
let outPath;

if (useFull) {
  input = fullInput;
  outPath = OUT_FULL;
  console.log("使用完整 build-info 输入（via-IR 跨单元编译，与 Hardhat 完全一致）");
} else {
  const minimalSources = {};
  for (const key of GOV_DEPS) {
    if (fullInput.sources[key]) {
      minimalSources[key] = fullInput.sources[key];
    }
  }
  input = {
    language: fullInput.language,
    sources: minimalSources,
    settings: fullInput.settings,
  };
  outPath = OUT_MIN;
}

const json = JSON.stringify(input, null, 2);
fs.writeFileSync(outPath, json, "utf-8");
console.log("已导出到:", outPath);
console.log("文件大小:", (json.length / 1024).toFixed(1), "KB");
if (!useFull) {
  console.log("包含源文件:", Object.keys(input.sources).join(", "));
  console.log("\n若验证仍失败，请尝试: node scripts/exportGovernanceModuleFromBuildInfo.mjs --full");
}
