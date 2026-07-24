#!/usr/bin/env node
/**
 * 导出 ConetTreasury 栈 BaseScan 验证 JSON — 与 BeamioUserCard 相同路径：
 *   npm run clean && npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs <ContractKey> --full
 *
 * 输出（约 1.2–1.5 MB / 合约）:
 *   deployments/base-{ContractKey}-standard-input-FULL.json
 *   deployments/base-{ContractKey}-basescan-verify-meta.txt
 *   deployments/base-ConetTreasuryStack-verify-bundle.json
 *
 * 对照: deployments/base-BeamioUserCard-standard-input-FULL.json
 *       npm run export:standard-json:full:usercard-stack
 */

import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { AbiCoder, getAddress } from "ethers";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const deploymentsDir = path.join(root, "deployments");

/** 跨链同址栈（CoNET + Base CREATE2） */
const TREASURY = getAddress("0xa311c8fBE7CafC611603Ee925465A62493B73B30");
const PEER = getAddress("0x025eC62F801B2f63d5C5b3eB066bab21B12Bbeb5");
/** 新版 UUPS wCNET proxy；旧非 UUPS 地址不得再作为 canonical。 */
const WCNET = getAddress("0x40B059e13d16B1C1E4dE032B04C5fbE554e0fA21");
const WCNET_IMPL = getAddress("0x5BD672918E4a2F37109b308f26125690b2861C99");
const CONET_USDC = getAddress("0xfD0D7B0706AaB5E4351bcED37bC3C77ed6813907");
const BUINT = getAddress("0x54ac4672cE75EC5ACebaeF1a7aFC6F49E77Ae9Ae");
const GB_TOKEN = getAddress("0xC3EF02DaE632b4C10abB66e07d92a387c10838D8");
const INITIAL_MINER = getAddress("0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1");

const STACK = [
  {
    exportKey: "ConetTreasury",
    label: "ConetTreasury",
    address: TREASURY,
    constructorTypes: ["address"],
    constructorValues: [INITIAL_MINER],
  },
  {
    exportKey: "ConetTreasuryPeer",
    label: "ConetTreasuryPeer",
    address: PEER,
    constructorTypes: ["address"],
    constructorValues: [TREASURY],
  },
  {
    exportKey: "FactoryERC20Upgradeable",
    label: "wCNET",
    address: WCNET_IMPL,
    constructorTypes: [],
    constructorValues: [],
  },
];

const CONTRACT_NAME_MAP = {
  ConetTreasury: ["project/src/b-unit/conetTreasury.sol", "ConetTreasury"],
  ConetTreasuryPeer: ["project/src/b-unit/ConetTreasuryPeer.sol", "ConetTreasuryPeer"],
  FactoryERC20: ["project/src/b-unit/FactoryERC20.sol", "FactoryERC20"],
  FactoryERC20Upgradeable: [
    "project/src/b-unit/FactoryERC20Upgradeable.sol",
    "FactoryERC20Upgradeable",
  ],
};

function encodeConstructorArgs(types, values) {
  if (types.length === 0) return "(none)";
  return AbiCoder.defaultAbiCoder().encode(types, values);
}

function contractNameFor(exportKey) {
  const [sourceKey, contractName] = CONTRACT_NAME_MAP[exportKey];
  return `${sourceKey}:${contractName}`;
}

function jsonRelFor(exportKey) {
  return `deployments/base-${exportKey}-standard-input-FULL.json`;
}

function exportFullStandardJson(exportKey) {
  execSync(`node scripts/exportStandardJsonFromBuildInfo.mjs ${exportKey} --full`, {
    cwd: root,
    stdio: "inherit",
  });
}

function writeMeta(item, contractName) {
  const jsonRel = jsonRelFor(item.exportKey);
  const jsonAbs = path.join(root, jsonRel);
  const sizeMb = fs.existsSync(jsonAbs) ? (fs.statSync(jsonAbs).size / 1024 / 1024).toFixed(2) : "?";
  const args = encodeConstructorArgs(item.constructorTypes, item.constructorValues);
  const meta = [
    `Contract Name: ${contractName}`,
    `Address: ${item.address}`,
    `Constructor Args ABI-encoded: ${args}`,
    `Standard JSON: ${jsonRel} (${sizeMb} MB — build-info FULL，与 BeamioUserCard 同款)`,
    "Network: base (chainId 8453)",
    `Generated: ${new Date().toISOString()}`,
    "Compiler: v0.8.35+commit.47b9dedd",
    "Optimization: enabled, runs 0, viaIR true, evmVersion cancun, bytecodeHash none",
    "",
    "Regenerate (与 BeamioUserCard 相同流程):",
    "  npm run clean && npm run compile",
    `  node scripts/exportStandardJsonFromBuildInfo.mjs ${item.exportKey} --full`,
    "  或: node scripts/exportConetTreasuryStackStandardJson.mjs",
    "  再: node scripts/exportConetTreasuryStackBaseScanFormJson.mjs",
    "",
    "BaseScan UI:",
    "  1) Solidity (Standard-Json-Input)",
    "  2) Compiler v0.8.35+commit.47b9dedd",
    `  3) Upload ${path.basename(jsonRel)}（须 ~1 MB+，勿用 ~79 KB 旧子集）`,
    "  4) Contract Name（若 UI 有该字段）:",
    `     ${contractName}`,
    "  5) Constructor Arguments (no 0x):",
    args === "(none)" ? "     (none)" : `     ${args.startsWith("0x") ? args.slice(2) : args}`,
    "",
    "CLI（推荐 — 显式 contractname）:",
    `  BASESCAN_API_KEY=... npx tsx scripts/verifyConetTreasuryStackBaseScan.ts ${item.exportKey}`,
    "",
    "禁止: settings.compilationTarget（BaseScan Unknown key）；勿用未 --full 的 build-info 子集。",
    "",
  ].join("\n");
  const metaPath = path.join(deploymentsDir, `base-${item.exportKey}-basescan-verify-meta.txt`);
  fs.writeFileSync(metaPath, meta, "utf-8");
  console.log("meta:", path.basename(metaPath));
  return { ...item, contractName, jsonRel, constructorArgs: args };
}

function main() {
  console.log("Export ConetTreasury stack Standard JSON FULL (BeamioUserCard / build-info path)\n");
  const bundle = [];
  for (const item of STACK) {
    console.log(`\n=== ${item.label} (${item.exportKey}) ===`);
    exportFullStandardJson(item.exportKey);
    bundle.push(writeMeta(item, contractNameFor(item.exportKey)));
  }
  const bundlePath = path.join(deploymentsDir, "base-ConetTreasuryStack-verify-bundle.json");
  const serializable = bundle.map((b) => ({
    ...b,
    constructorValues: b.constructorValues?.map((v) =>
      typeof v === "bigint" ? v.toString() : v
    ),
  }));
  fs.writeFileSync(
    bundlePath,
    JSON.stringify(
      {
        network: "base",
        chainId: 8453,
        generatedAt: new Date().toISOString(),
        exportMode: "build-info-full",
        reference: "deployments/base-BeamioUserCard-standard-input-FULL.json",
        contracts: serializable,
      },
      null,
      2
    ) + "\n",
    "utf-8"
  );
  console.log("\nBundle:", bundlePath);
}

main();
