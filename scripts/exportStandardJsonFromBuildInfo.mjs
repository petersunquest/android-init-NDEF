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
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardFactoryPaymasterV07 --full
 *   # Base 上 0x291B… QuoteHelper：须 runs=50，且勿用 bytecodeHash:none / revert strip（与部署期一致），否则链上 bytecode 尾部队列元数据不匹配、BaseScan 报错。
 *   BEAMIO_SOLC_VERIFY_QUOTEHELPER_V07=1 npm run clean && BEAMIO_SOLC_VERIFY_QUOTEHELPER_V07=1 npm run compile && node scripts/exportStandardJsonFromBuildInfo.mjs BeamioQuoteHelperV07 --full
 *   # 同上（runs=50、默认 metadata）：BeamioFactoryPaymasterV07（aaFactory_指向的 AA 工厂，如 0xD86403…）
 *   BEAMIO_SOLC_VERIFY_QUOTEHELPER_V07=1 npm run clean && BEAMIO_SOLC_VERIFY_QUOTEHELPER_V07=1 npm run compile && node scripts/exportStandardJsonFromBuildInfo.mjs BeamioFactoryPaymasterV07 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs MembershipStatsModule --full
 *
 * Base 主网 BeamioOracle 0xDa4…A9A2B 与当前 hardhat（0.8.33 + viaIR + runs=0等）不一致，
 * 勿用本脚本从 build-info 导出该地址验证 JSON；请用:
 *   node scripts/buildBeamioOracleBaseOnchainVerifyStandardJson.mjs
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
  BeamioUserCardAdminGatewayLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardAdminGatewayLib.sol",
    contractName: "BeamioUserCardAdminGatewayLib",
  },
  BeamioUserCardFaucetGatewayLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardFaucetGatewayLib.sol",
    contractName: "BeamioUserCardFaucetGatewayLib",
  },
  BeamioUserCardGatewayMintLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardGatewayMintLib.sol",
    contractName: "BeamioUserCardGatewayMintLib",
  },
  BeamioUserCardGovernanceLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardGovernanceLib.sol",
    contractName: "BeamioUserCardGovernanceLib",
  },
  BeamioUserCardIssuedNftGatewayLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardIssuedNftGatewayLib.sol",
    contractName: "BeamioUserCardIssuedNftGatewayLib",
  },
  BeamioUserCardModuleRouterLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardModuleRouterLib.sol",
    contractName: "BeamioUserCardModuleRouterLib",
  },
  BeamioUserCardRedeemGatewayLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardRedeemGatewayLib.sol",
    contractName: "BeamioUserCardRedeemGatewayLib",
  },
  BeamioUserCardReferrerLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol",
    contractName: "BeamioUserCardReferrerLib",
  },
  ReferrerRegistryLib: {
    sourceKey: "project/src/BeamioUserCard/ReferrerRegistryLib.sol",
    contractName: "ReferrerRegistryLib",
  },
  BeamioUserCardUpdateLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardUpdateLib.sol",
    contractName: "BeamioUserCardUpdateLib",
  },
  BeamioUserCardViewsLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardViewsLib.sol",
    contractName: "BeamioUserCardViewsLib",
  },
  BeamioUserCardMembershipGateLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardMembershipGateLib.sol",
    contractName: "BeamioUserCardMembershipGateLib",
  },
  BeamioUserCard: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCard.sol",
    contractName: "BeamioUserCard",
  },
  BeamioUserCardFactoryPaymasterV07: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol",
    contractName: "BeamioUserCardFactoryPaymasterV07",
  },
  BeamioUserCardFactoryExecuteLib: {
    sourceKey: "project/src/BeamioUserCard/BeamioUserCardFactoryExecuteLib.sol",
    contractName: "BeamioUserCardFactoryExecuteLib",
  },
  BeamioUserCardIssuedNftModuleV1: {
    sourceKey: "project/src/BeamioUserCard/IssuedNftModule.sol",
    contractName: "BeamioUserCardIssuedNftModuleV1",
  },
  BeamioUserCardIssuedNftModuleV2: {
    sourceKey: "project/src/BeamioUserCard/IssuedNftModuleV2.sol",
    contractName: "BeamioUserCardIssuedNftModuleV2",
  },
  BeamioQuoteHelperV07: {
    sourceKey: "project/src/BeamioUserCard/BeamioQuoteHelperV07.sol",
    contractName: "BeamioQuoteHelperV07",
  },
  BeamioOracle: {
    sourceKey: "project/src/BeamioUserCard/BeamioOracle.sol",
    contractName: "BeamioOracle",
  },
  AdminStatsQueryModule: {
    sourceKey: "project/src/BeamioUserCard/AdminStatsQueryModule.sol",
    contractName: "BeamioUserCardAdminStatsQueryModuleV1",
  },
  BeamioUserCardAdminStatsQueryModuleV2: {
    sourceKey: "project/src/BeamioUserCard/AdminStatsQueryModuleV2.sol",
    contractName: "BeamioUserCardAdminStatsQueryModuleV2",
  },
  BeamioUserCardAdminStatsQueryModuleV3: {
    sourceKey: "project/src/BeamioUserCard/AdminStatsQueryModuleV3.sol",
    contractName: "BeamioUserCardAdminStatsQueryModuleV3",
  },
  GovernanceModule: {
    sourceKey: "project/src/BeamioUserCard/GovernanceModule.sol",
    contractName: "BeamioUserCardGovernanceModuleV1",
  },
  MembershipStatsModule: {
    sourceKey: "project/src/BeamioUserCard/MembershipStatsModule.sol",
    contractName: "BeamioUserCardMembershipStatsModuleV1",
  },
  ChargeRewardModule: {
    sourceKey: "project/src/BeamioUserCard/ChargeRewardModule.sol",
    contractName: "BeamioUserCardChargeRewardModuleV1",
  },
  BeamioUserCardChargeRewardModuleV2: {
    sourceKey: "project/src/BeamioUserCard/ChargeRewardModuleV2.sol",
    contractName: "BeamioUserCardChargeRewardModuleV2",
  },
  RedeemModule: {
    sourceKey: "project/src/BeamioUserCard/RedeemModule.sol",
    contractName: "BeamioUserCardRedeemModuleVNext",
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
  ConetTreasury: {
    sourceKey: "project/src/b-unit/conetTreasury.sol",
    contractName: "ConetTreasury",
  },
  ConetTreasuryLiquidityStaking: {
    sourceKey: "project/src/b-unit/ConetTreasuryLiquidityStaking.sol",
    contractName: "ConetTreasuryLiquidityStaking",
  },
  ConetTreasuryPeer: {
    sourceKey: "project/src/b-unit/ConetTreasuryPeer.sol",
    contractName: "ConetTreasuryPeer",
  },
  FactoryERC20: {
    sourceKey: "project/src/b-unit/FactoryERC20.sol",
    contractName: "FactoryERC20",
  },
  FactoryERC20Upgradeable: {
    sourceKey: "project/src/b-unit/FactoryERC20Upgradeable.sol",
    contractName: "FactoryERC20Upgradeable",
  },
  BeamioBUnits: {
    sourceKey: "project/src/b-unit/BUint.sol",
    contractName: "BeamioBUnits",
  },
  BUnitAirdrop: {
    sourceKey: "project/src/b-unit/BUnitAirdrop.sol",
    contractName: "BUnitAirdrop",
  },
  BUnitAirdropV2: {
    sourceKey: "project/src/b-unit/BUnitAirdropV2.sol",
    contractName: "BUnitAirdropV2",
  },
  ReferralRegistryVaultV1: {
    sourceKey: "project/src/mainnet/ReferralRegistryVaultV1.sol",
    contractName: "ReferralRegistryVaultV1",
  },
  BuintRedeemAirdrop: {
    sourceKey: "project/src/b-unit/BuintRedeemAirdrop.sol",
    contractName: "BuintRedeemAirdrop",
  },
  ConetGB1155: {
    sourceKey: "project/src/b-unit/GB.sol",
    contractName: "ConetGB1155",
  },
  ConetGB_total: {
    sourceKey: "project/src/b-unit/gbTotal.sol",
    contractName: "ConetGB_total",
  },
  ConetGB_userTotal: {
    sourceKey: "project/src/b-unit/gbUserTotal.sol",
    contractName: "ConetGB_userTotal",
  },
  ConetLabMiningPool: {
    sourceKey: "project/src/mainnet/ConetLabMiningPool.sol",
    contractName: "ConetLabMiningPool",
  },
  ConetTeamCnetHold: {
    sourceKey: "project/src/mainnet/ConetTeamCnetHold.sol",
    contractName: "ConetTeamCnetHold",
  },
};

const buildInfoDir = path.join(__dirname, "../artifacts/build-info");
const buildInfoFiles = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));
if (buildInfoFiles.length === 0) {
  console.error("未找到 build-info，请先运行: npm run clean && npm run compile");
  process.exit(1);
}

/** 多份 build-info 时，选用 **sources 最多** 的那份（via-IR 须完整编译单元，禁止小子集） */
function resolveBuildInfoPath(sourceKey) {
  let bestPath = null;
  let bestCount = -1;
  for (const f of buildInfoFiles) {
    const p = path.join(buildInfoDir, f);
    try {
      const j = JSON.parse(fs.readFileSync(p, "utf-8"));
      const sources = j.input?.sources;
      if (!sources?.[sourceKey]) continue;
      const count = Object.keys(sources).length;
      if (count > bestCount) {
        bestCount = count;
        bestPath = p;
      }
    } catch {
      /* skip */
    }
  }
  return bestPath;
}

const contractArg = process.argv[2];
const useFull = process.argv.includes("--full");

if (!contractArg || !CONFIG[contractArg]) {
  console.error("用法: node scripts/exportStandardJsonFromBuildInfo.mjs <Contract> --full");
  console.error("支持的 Contract:", Object.keys(CONFIG).join(", "));
  process.exit(1);
}

if (!useFull) {
  console.error("错误: 必须传入 --full。");
  console.error(
    "精简版仅含直接 import，缺少传递依赖（例如 BeamioAccount → BeamioContainerLayoutConstantsV07.sol），BaseScan 会报 ParserError / File import callback not supported。"
  );
  process.exit(1);
}

const cfg = CONFIG[contractArg];
const outPath = path.join(__dirname, "../deployments", `base-${contractArg}-standard-input-FULL.json`);

const buildInfoPath = resolveBuildInfoPath(cfg.sourceKey);
if (!buildInfoPath) {
  console.error(`未找到包含 ${cfg.sourceKey} 的 build-info，请先 npm run compile`);
  process.exit(1);
}

console.log("使用 build-info:", path.basename(buildInfoPath));

const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
const fullInput = buildInfo.input;
console.log("  sources:", Object.keys(fullInput.sources).length);

if (!fullInput.sources[cfg.sourceKey]) {
  console.error(`build-info 中未找到 ${cfg.sourceKey}`);
  process.exit(1);
}

const input = JSON.parse(JSON.stringify(fullInput));
console.log("使用完整 build-info 输入（via-IR 与 Hardhat 完全一致）");
// Hardhat build-info 可能含 compilationTarget；BaseScan solc 报 Unknown key，须删除。
if (input.settings?.compilationTarget) {
  delete input.settings.compilationTarget;
}

/**
 * Hardhat 3 npm 依赖会以 `npm/@scope/pkg@version/...` 作为 source key，并配 `context:prefix=target`
 * 上下文重映射。原生 solc 能解析，但 BaseScan 验证管线处理不了这种 key/上下文重映射，
 * 会导致 import 解析失败、编译产出为空（"Compiled Contract Bytecode for ''"）。
 *
 * 这里把 npm key 还原成它们的标准导入路径（如 `@openzeppelin/contracts/...`），并清空 remappings，
 * 使 JSON 形状与已成功 UI 验证的 BeamioUserCard（remappings=[]、key 全为可直接 import 的路径）一致。
 * 对无 npm 依赖的合约为 no-op。
 */
function normalizeNpmSourceKeysForBaseScan(stdInput) {
  const rawRemappings = Array.isArray(stdInput.settings?.remappings) ? stdInput.settings.remappings : [];
  // 解析 remappings: 形如 `context:prefix=target` 或 `prefix=target`
  const npmPrefixMap = []; // { prefix, target }
  for (const r of rawRemappings) {
    const eq = r.indexOf("=");
    if (eq < 0) continue;
    const left = r.slice(0, eq);
    const target = r.slice(eq + 1);
    if (!target.startsWith("npm/")) continue;
    const colon = left.indexOf(":");
    const prefix = colon >= 0 ? left.slice(colon + 1) : left;
    npmPrefixMap.push({ prefix, target });
  }
  // 最长 target 优先，避免前缀互相覆盖
  npmPrefixMap.sort((a, b) => b.target.length - a.target.length);

  function remapKey(key) {
    if (!key.startsWith("npm/")) return key;
    for (const { prefix, target } of npmPrefixMap) {
      if (key.startsWith(target)) return prefix + key.slice(target.length);
    }
    return key; // 未被 remapping 覆盖的 npm key（保留并在下方告警）
  }

  const newSources = {};
  for (const [k, v] of Object.entries(stdInput.sources)) {
    newSources[remapKey(k)] = v;
  }
  stdInput.sources = newSources;

  if (stdInput.settings?.libraries && typeof stdInput.settings.libraries === "object") {
    const newLibs = {};
    for (const [k, v] of Object.entries(stdInput.settings.libraries)) {
      newLibs[remapKey(k)] = v;
    }
    stdInput.settings.libraries = newLibs;
  }

  // 归一化后不再需要 remappings（导入路径已是 key 本身）
  if (stdInput.settings) stdInput.settings.remappings = [];

  const leftoverNpm = Object.keys(stdInput.sources).filter((k) => k.startsWith("npm/"));
  if (leftoverNpm.length > 0) {
    console.warn("警告: 仍有未被 remapping 覆盖的 npm/ source key:", leftoverNpm.slice(0, 5));
  }
}

normalizeNpmSourceKeysForBaseScan(input);

function artifactPathForConfig(config) {
  const artifactSourcePath = config.sourceKey.replace(/^project\//, "");
  return path.join(__dirname, "../artifacts", artifactSourcePath, `${config.contractName}.json`);
}

function readUserCardLibraryAddresses() {
  const out = {};
  const p = path.join(__dirname, "../deployments/base-BeamioUserCardLibraries.json");
  if (fs.existsSync(p)) {
    const j = JSON.parse(fs.readFileSync(p, "utf-8"));
    const contracts = j.contracts ?? {};
    for (const [name, value] of Object.entries(contracts)) {
      if (value?.address) out[name] = value.address;
    }
  }
  // CoNET 224422 部署的 linked lib（验证商户卡 runtime 须用链上实际地址，覆盖 Base 表）
  const conetPath = path.join(__dirname, "../deployments/conet-addresses.json");
  if (fs.existsSync(conetPath)) {
    const c = JSON.parse(fs.readFileSync(conetPath, "utf-8"));
    const conetLibKeyToName = {
      beamioUserCardFormattingLib: "BeamioUserCardFormattingLib",
      beamioUserCardTransferLib: "BeamioUserCardTransferLib",
      beamioUserCardAdminGatewayLib: "BeamioUserCardAdminGatewayLib",
      beamioUserCardFaucetGatewayLib: "BeamioUserCardFaucetGatewayLib",
      beamioUserCardGatewayMintLib: "BeamioUserCardGatewayMintLib",
      beamioUserCardGovernanceLib: "BeamioUserCardGovernanceLib",
      beamioUserCardIssuedNftGatewayLib: "BeamioUserCardIssuedNftGatewayLib",
      beamioUserCardModuleRouterLib: "BeamioUserCardModuleRouterLib",
      beamioUserCardRedeemGatewayLib: "BeamioUserCardRedeemGatewayLib",
      beamioUserCardReferrerLib: "BeamioUserCardReferrerLib",
      beamioUserCardUpdateLib: "BeamioUserCardUpdateLib",
      beamioUserCardViewsLib: "BeamioUserCardViewsLib",
      beamioUserCardMembershipGateLib: "BeamioUserCardMembershipGateLib",
    };
    for (const [key, libName] of Object.entries(conetLibKeyToName)) {
      if (c[key]) out[libName] = c[key];
    }
  }
  // ConetTreasuryPeer CREATE2 libs（同址 CoNET/Base）
  const peerMetaPath = path.join(__dirname, "../deployments/conetTreasuryPeer-create2-meta.json");
  if (fs.existsSync(peerMetaPath)) {
    const peerMeta = JSON.parse(fs.readFileSync(peerMetaPath, "utf-8"));
    if (peerMeta.wrappedLibAddress) {
      out.ConetTreasuryPeerWrappedLib = peerMeta.wrappedLibAddress;
    }
    if (peerMeta.stableSwapLibAddress) {
      out.ConetTreasuryPeerStableSwapLib = peerMeta.stableSwapLibAddress;
    }
  }
  return out;
}

const artifactPath = artifactPathForConfig(cfg);
if (fs.existsSync(artifactPath)) {
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  const linkReferences = artifact.deployedLinkReferences ?? artifact.linkReferences ?? {};
  const libraryAddresses = readUserCardLibraryAddresses();
  for (const [sourceName, libs] of Object.entries(linkReferences)) {
    for (const libName of Object.keys(libs)) {
      const addr = libraryAddresses[libName];
      if (!addr) {
        console.error(`缺少 ${contractArg} 验证所需 library 地址: ${libName}`);
        process.exit(1);
      }
      input.settings ??= {};
      input.settings.libraries ??= {};
      input.settings.libraries[sourceName] ??= {};
      input.settings.libraries[sourceName][libName] = addr;
    }
  }
}

const json = JSON.stringify(input, null, 2);
fs.writeFileSync(outPath, json, "utf-8");
console.log("已导出到:", outPath);
console.log("文件大小:", (json.length / 1024).toFixed(1), "KB");
console.log("Contract Name:", `${cfg.sourceKey}:${cfg.contractName}`);