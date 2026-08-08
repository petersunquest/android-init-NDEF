#!/usr/bin/env node
/**
 * 从 build-info 导出 BaseScan 验证用 Standard JSON
 *
 * via-IR 下，精简版（仅直接依赖）会导致 BaseScan 编译出与链上不同的 bytecode。
 * 必须使用 --full 导出完整 build-info 输入，与 Hardhat 编译输入完全一致。
 *
 * 用法:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModule
 *   node scripts/exportStandardJsonFromBuildInfo.mjs GovernanceModule
 *   node scripts/exportStandardJsonFromBuildInfo.mjs GovernanceModule --full
 *
 * 输出: deployments/base-{Contract}-standard-input-FULL.json
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const CONFIG = {
  GenesisNodeReferralVaultV1: {
    sourceKey: "project/src/mainnet/GenesisNodeReferralVaultV1.sol",
    contractName: "GenesisNodeReferralVaultV1",
  },
  BeamioUserCard: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCard.sol",
    contractName: "BeamioUserCard",
  },
  AdminStatsQueryModule: {
    sourceKey: "project/src/BeamioUserCard/AdminStatsQueryModule.sol",
    contractName: "BeamioUserCardAdminStatsQueryModuleV1",
  },
  AdminStatsQueryModuleV4: {
    sourceKey: "project/src/BeamioUserCard/AdminStatsQueryModuleV4.sol",
    contractName: "BeamioUserCardAdminStatsQueryModuleV4",
  },
  BeamioUserCardIssuedNftModuleV2: {
    sourceKey: "project/src/BeamioUserCard/IssuedNftModuleV2.sol",
    contractName: "BeamioUserCardIssuedNftModuleV2",
  },
  BeamioUserCardChargeRewardModuleV2: {
    sourceKey: "project/src/BeamioUserCard/ChargeRewardModuleV2.sol",
    contractName: "BeamioUserCardChargeRewardModuleV2",
  },
  BeamioUserCardReferrerLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol",
    contractName: "BeamioUserCardReferrerLib",
  },
  ReferrerRegistryLib: {
    sourceKey: "project/src/BeamioUserCard/ReferrerRegistryLib.sol",
    contractName: "ReferrerRegistryLib",
  },

  GovernanceModule: {
    sourceKey: "project/src/BeamioUserCard/GovernanceModule.sol",
    contractName: "BeamioUserCardGovernanceModuleV1",
  },
  ConetTreasuryPeer: {
    sourceKey: "project/src/b-unit/ConetTreasuryPeer.sol",
    contractName: "ConetTreasuryPeer",
  },
  ConetTreasuryPeerStableSwapOffline: {
    sourceKey: "project/src/b-unit/ConetTreasuryPeerStableSwapOffline.sol",
    contractName: "ConetTreasuryPeerStableSwapOffline",
  },
  ConetTreasuryPeerDepositLib: {
    sourceKey: "project/src/b-unit/ConetTreasuryPeerDepositLib.sol",
    contractName: "ConetTreasuryPeerDepositLib",
  },
  ConetTreasuryPeerStableSwapSigLib: {
    sourceKey: "project/src/b-unit/ConetTreasuryPeerStableSwapSigLib.sol",
    contractName: "ConetTreasuryPeerStableSwapSigLib",
  },
  ConetTreasuryPeerWrappedLib: {
    sourceKey: "project/src/b-unit/ConetTreasuryPeerWrappedLib.sol",
    contractName: "ConetTreasuryPeerWrappedLib",
  },
  ConetTreasuryPeerStableSwapLib: {
    sourceKey: "project/src/b-unit/ConetTreasuryPeerStableSwapLib.sol",
    contractName: "ConetTreasuryPeerStableSwapLib",
  },
  GBTokenV2: {
    sourceKey: "project/src/b-unit/GBTokenV2.sol",
    contractName: "GBTokenV2",
  },
  GBDepinAirdrop: {
    sourceKey: "project/src/b-unit/GBDepinAirdrop.sol",
    contractName: "GBDepinAirdrop",
  },
  DepinGbSettlement1155: {
    sourceKey: "project/src/b-unit/DepinGbSettlement1155.sol",
    contractName: "DepinGbSettlement1155",
  },
  DeveloperTokenFxRegistry: {
    sourceKey: "project/src/b-unit/DeveloperTokenFxRegistry.sol",
    contractName: "DeveloperTokenFxRegistry",
  },
  TreasuryBridgeV3: {
    sourceKey: "project/src/b-unit/TreasuryBridgeV3.sol",
    contractName: "TreasuryBridgeV3",
  },
  TreasuryCanonicalERC20V3: {
    sourceKey: "project/src/b-unit/TreasuryCanonicalERC20V3.sol",
    contractName: "TreasuryCanonicalERC20V3",
  },
  DeveloperFxIssuer: {
    sourceKey: "project/src/b-unit/DeveloperFxIssuer.sol",
    contractName: "DeveloperFxIssuer",
  },
  TreasuryDeveloperFxLib: {
    sourceKey: "project/src/b-unit/TreasuryDeveloperFxLib.sol",
    contractName: "TreasuryDeveloperFxLib",
  },
};

const buildInfoDir = path.join(__dirname, "../artifacts/build-info");
const buildInfoFiles = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));
if (buildInfoFiles.length === 0) {
  console.error("未找到 build-info，请先运行: npm run clean && npm run compile");
  process.exit(1);
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

/**
 * via-IR: prefer build-info that contains sourceKey.
 * Among matches, prefer units that also contain ChargeRewardModuleV2 when exporting
 * UserCard libs/modules (same Hardhat compile unit as live CoNET module deploys).
 * Prefer content matching the on-disk Solidity file so stale larger units lose.
 */
function resolveBuildInfoPath(sourceKey) {
  const preferCompanion = "project/src/BeamioUserCard/ChargeRewardModuleV2.sol";
  const diskRel = sourceKey.startsWith("project/")
    ? sourceKey.slice("project/".length)
    : sourceKey;
  const diskPath = path.join(__dirname, "..", diskRel);
  let diskContent = null;
  try {
    diskContent = fs.readFileSync(diskPath, "utf-8");
  } catch {
    /* optional */
  }
  let best = null;
  let bestScore = -1;
  for (const f of buildInfoFiles) {
    const p = path.join(buildInfoDir, f);
    try {
      const j = JSON.parse(fs.readFileSync(p, "utf-8"));
      const sources = j?.input?.sources || {};
      const n = Object.keys(sources).length;
      const hasKey = Boolean(sources[sourceKey]);
      if (!hasKey) continue;
      const biContent = sources[sourceKey]?.content || "";
      const contentExact = diskContent != null && biContent === diskContent ? 1 : 0;
      const contentLenClose =
        diskContent != null
          ? Math.max(0, 50_000 - Math.abs(biContent.length - diskContent.length))
          : 0;
      // score: exact disk match >> companion unit >> content length proximity >> source count
      const score =
        contentExact * 10_000_000 +
        (sources[preferCompanion] &&
        sourceKey.startsWith("project/src/BeamioUserCard/")
          ? 100_000
          : 0) +
        contentLenClose +
        n;
      if (score > bestScore) {
        best = p;
        bestScore = score;
      }
    } catch {
      /* skip */
    }
  }
  if (!best) throw new Error("no readable build-info");
  const n = Object.keys(JSON.parse(fs.readFileSync(best, "utf-8"))?.input?.sources || {}).length;
  console.log(`build-info: ${path.basename(best)} (sources=${n})`);
  return best;
}
const BUILD_INFO = resolveBuildInfoPath(cfg.sourceKey);

const outPath = path.join(
  __dirname,
  "../deployments",
  `base-${contractArg}-standard-input-${useFull ? "FULL" : "min"}.json`
);

const buildInfo = JSON.parse(fs.readFileSync(BUILD_INFO, "utf-8"));
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