#!/usr/bin/env node
/**
 * 从 build-info 导出 BaseScan 验证用 Standard JSON
 *
 * via-IR 下，精简版（仅直接依赖）会导致 BaseScan 编译出与链上不同的 bytecode。
 * 必须使用 --full 导出完整 build-info 输入，与 Hardhat 编译输入完全一致。
 *
 * 用法:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModule --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioAccount --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioFactoryPaymasterV07 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioContainerModuleExternalLibV07 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioContainerModuleExternalLib2V07 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioContainerModuleV07 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardFormattingLib --full
 *
 * 输出: deployments/base-{Contract}-standard-input-FULL.json
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const CONFIG = {
  BeamioUserCardFormattingLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardFormattingLib.sol",
    contractName: "BeamioUserCardFormattingLib",
  },
  BeamioUserCardTransferLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardTransferLib.sol",
    contractName: "BeamioUserCardTransferLib",
  },
  BeamioUserCard: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCard.sol",
    contractName: "BeamioUserCard",
  },
  AdminStatsQueryModule: {
    sourceKey: "project/src/BeamioUserCard/AdminStatsQueryModule.sol",
    contractName: "BeamioUserCardAdminStatsQueryModuleV1",
  },
  GovernanceModule: {
    sourceKey: "project/src/BeamioUserCard/GovernanceModule.sol",
    contractName: "BeamioUserCardGovernanceModuleV1",
  },
  BeamioAccount: {
    sourceKey: "project/src/BeamioAccount/BeamioAccount.sol",
    contractName: "BeamioAccount",
  },
  BeamioFactoryPaymasterV07: {
    sourceKey: "project/src/BeamioAccount/BeamioFactoryPaymasterV07.sol",
    contractName: "BeamioFactoryPaymasterV07",
  },
  BeamioContainerModuleV07: {
    sourceKey: "project/src/BeamioAccount/BeamioContainerModuleV07.sol",
    contractName: "BeamioContainerModuleV07",
  },
  BeamioContainerModuleExternalLibV07: {
    sourceKey: "project/src/BeamioAccount/BeamioContainerModuleExternalLibV07.sol",
    contractName: "BeamioContainerModuleExternalLibV07",
  },
  BeamioContainerModuleExternalLib2V07: {
    sourceKey: "project/src/BeamioAccount/BeamioContainerModuleExternalLib2V07.sol",
    contractName: "BeamioContainerModuleExternalLib2V07",
  },
  BeamioAccountDeployer: {
    sourceKey: "project/src/BeamioAccount/BeamioAccountDeployer.sol",
    contractName: "BeamioAccountDeployer",
  },
};

const buildInfoDir = path.join(__dirname, "../artifacts/build-info");
const buildInfoFiles = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));
if (buildInfoFiles.length === 0) {
  console.error("未找到 build-info，请先运行: npm run clean && npm run compile");
  process.exit(1);
}

/** 多份 build-info 时，选用包含目标源文件的那份 */
function resolveBuildInfoPath(sourceKey) {
  for (const f of buildInfoFiles) {
    const p = path.join(buildInfoDir, f);
    try {
      const j = JSON.parse(fs.readFileSync(p, "utf-8"));
      if (j.input?.sources?.[sourceKey]) return p;
    } catch {
      /* skip */
    }
  }
  return null;
}

const contractArg = process.argv[2];
const useFull = process.argv.includes("--full");

if (!contractArg || !CONFIG[contractArg]) {
  console.error("用法: node scripts/exportStandardJsonFromBuildInfo.mjs <Contract> [--full]");
  console.error("支持的 Contract:", Object.keys(CONFIG).join(", "));
  console.error("建议始终使用 --full，以确保 via-IR 下 bytecode 与链上一致");
  process.exit(1);
}

const cfg = CONFIG[contractArg];
const outPath = path.join(
  __dirname,
  "../deployments",
  `base-${contractArg}-standard-input-${useFull ? "FULL" : "min"}.json`
);

const buildInfoPath = resolveBuildInfoPath(cfg.sourceKey);
if (!buildInfoPath) {
  console.error(`未找到包含 ${cfg.sourceKey} 的 build-info，请先 npm run compile`);
  process.exit(1);
}

console.log("使用 build-info:", path.basename(buildInfoPath));

const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
const fullInput = buildInfo.input;

if (!fullInput.sources[cfg.sourceKey]) {
  console.error(`build-info 中未找到 ${cfg.sourceKey}`);
  process.exit(1);
}

let input;
if (useFull) {
  input = fullInput;
  console.log(`使用完整 build-info 输入（via-IR 与 Hardhat 完全一致）`);
} else {
  // 精简版：仅直接依赖（可能因 via-IR 导致 bytecode 不匹配）
  const deps = {
    [cfg.sourceKey]: fullInput.sources[cfg.sourceKey],
  };
  const content = fullInput.sources[cfg.sourceKey].content;
  const importRegex = /^\s*import\s+(?:[^'"]+from\s+)?["']([^"']+)["'];/gm;
  for (const m of content.matchAll(importRegex)) {
    const imp = m[1];
    let key;
    if (imp.startsWith("./") || imp.startsWith("../")) {
      const dir = path.dirname(cfg.sourceKey.replace("project/", ""));
      key = "project/" + path.join(dir, imp).replace(/\\/g, "/");
    } else {
      key = "project/" + imp;
    }
    if (fullInput.sources[key]) deps[key] = fullInput.sources[key];
  }
  input = {
    language: fullInput.language,
    sources: deps,
    settings: fullInput.settings,
  };
  console.log("使用精简源（若验证失败请加 --full）");
}

const json = JSON.stringify(input, null, 2);
fs.writeFileSync(outPath, json, "utf-8");
console.log("已导出到:", outPath);
console.log("文件大小:", (json.length / 1024).toFixed(1), "KB");
console.log("Contract Name:", `${cfg.sourceKey}:${cfg.contractName}`);