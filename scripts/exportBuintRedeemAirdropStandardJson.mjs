#!/usr/bin/env node
/**
 * 从 Hardhat build-info 导出 CoNET Blockscout 验证用 Standard JSON（完整输入，via-IR 安全）
 *
 * 用法:
 *   npm run clean && npm run compile
 *   node scripts/exportBuintRedeemAirdropStandardJson.mjs
 *
 * 输出:
 *   deployments/conet-BuintRedeemAirdrop-standard-input-FULL.json（全量 build-info）
 *   deployments/conet-BuintRedeemAirdrop-standard-input-SUBSET.json（b-unit + contracts，~400KB）
 *   deployments/conet-BuintRedeemAirdrop-conet-verify-meta.txt
 *
 * CoNET Explorer（nginx）对 multipart 体积极敏感：全量 ~1.1MB 易 413，**链上验证请用 SUBSET**。
 * Blockscout API 参考 scripts/verifyBUintAirdropStandardJson.ts
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { AbiCoder } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const SOURCE_KEY = "project/src/b-unit/BuintRedeemAirdrop.sol";
const CONTRACT_FQN = `${SOURCE_KEY}:BuintRedeemAirdrop`;
const COMPILER_VERSION = "v0.8.33+commit.64118f21";

const buildInfoDir = path.join(__dirname, "../artifacts/build-info");
const deployPath = path.join(__dirname, "../deployments/conet-BuintRedeemAirdrop.json");
const outJsonPath = path.join(__dirname, "../deployments/conet-BuintRedeemAirdrop-standard-input-FULL.json");
const outSubsetPath = path.join(__dirname, "../deployments/conet-BuintRedeemAirdrop-standard-input-SUBSET.json");
const outMetaPath = path.join(__dirname, "../deployments/conet-BuintRedeemAirdrop-conet-verify-meta.txt");

function subsetInput(fullInput) {
  const keys = Object.keys(fullInput.sources).filter(
    (k) => k.startsWith("project/src/b-unit") || k.startsWith("project/src/contracts")
  );
  const sources = {};
  for (const k of keys) sources[k] = fullInput.sources[k];
  return { language: fullInput.language, sources, settings: fullInput.settings };
}

function resolveBuildInfoPath() {
  if (!fs.existsSync(buildInfoDir)) return null;
  const files = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  for (const f of files) {
    const p = path.join(buildInfoDir, f);
    try {
      const j = JSON.parse(fs.readFileSync(p, "utf-8"));
      if (j.input?.sources?.[SOURCE_KEY]) return p;
    } catch {
      /* skip */
    }
  }
  return null;
}

function main() {
  const buildInfoPath = resolveBuildInfoPath();
  if (!buildInfoPath) {
    console.error(`未找到包含 ${SOURCE_KEY} 的 build-info，请先运行: npm run clean && npm run compile`);
    process.exit(1);
  }

  if (!fs.existsSync(deployPath)) {
    console.error("缺少 deployments/conet-BuintRedeemAirdrop.json，请先部署或恢复该文件");
    process.exit(1);
  }

  const deploy = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const buint = deploy.contracts?.BuintRedeemAirdrop?.buint;
  const initialRedeemAdmin = deploy.initialRedeemAdmin;
  const deployed = deploy.contracts?.BuintRedeemAirdrop?.address;
  if (!buint || !initialRedeemAdmin) {
    console.error("conet-BuintRedeemAirdrop.json 缺少 buint / initialRedeemAdmin");
    process.exit(1);
  }

  const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
  const fullInput = buildInfo.input;
  if (!fullInput?.sources?.[SOURCE_KEY]) {
    console.error("build-info 中未找到目标源文件");
    process.exit(1);
  }

  const json = JSON.stringify(fullInput, null, 2);
  fs.writeFileSync(outJsonPath, json, "utf-8");

  const subset = subsetInput(fullInput);
  const subsetJson = JSON.stringify(subset);
  fs.writeFileSync(outSubsetPath, JSON.stringify(subset, null, 2), "utf-8");

  const encoder = AbiCoder.defaultAbiCoder();
  const encoded = encoder.encode(["address", "address"], [buint, initialRedeemAdmin]);
  const constructorArgsHex = encoded.startsWith("0x") ? encoded.slice(2) : encoded;

  const viaIR = fullInput.settings?.viaIR ?? fullInput.settings?.viaIr;
  const meta = [
    "BuintRedeemAirdrop — CoNET Blockscout 验证元数据",
    "",
    `compiler_version: ${COMPILER_VERSION}`,
    `contract_name: ${CONTRACT_FQN}`,
    `constructor_args_hex (no 0x): ${constructorArgsHex}`,
    `deployed_address: ${deployed ?? "(见 conet-addresses.json)"}`,
    `standard_json_full: deployments/conet-BuintRedeemAirdrop-standard-input-FULL.json`,
    `standard_json_conet_api (推荐，避免 413): deployments/conet-BuintRedeemAirdrop-standard-input-SUBSET.json`,
    `subset_sources_count: ${Object.keys(subset.sources).length}`,
    `build_info_used: ${path.basename(buildInfoPath)}`,
    `viaIR (settings): ${viaIR}`,
    "",
    "CoNET Blockscout: https://mainnet.conet.network/",
    "API 示例:",
    `  POST .../api/v2/smart-contracts/<address>/verification/via/standard-input`,
    "  form: compiler_version, contract_name, files[0]=standard-input.json, constructor_args, autodetect_constructor_args=false, license_type=mit",
  ].join("\n");

  fs.writeFileSync(outMetaPath, meta + "\n", "utf-8");

  console.log("使用 build-info:", path.basename(buildInfoPath));
  console.log("viaIR:", viaIR);
  console.log("已写入:", outJsonPath, `(${(json.length / 1024).toFixed(1)} KB)`);
  console.log("已写入:", outSubsetPath, `(${(subsetJson.length / 1024).toFixed(1)} KB, ${Object.keys(subset.sources).length} sources)`);
  console.log("已写入:", outMetaPath);
  console.log("Contract Name (Explorer):", CONTRACT_FQN);
  console.log("constructor_args_hex:", constructorArgsHex);
}

main();
