#!/usr/bin/env node
/**
 * 导出 Beamio AA + Oracle 栈 BaseScan 验证 JSON（FULL + meta + bundle）。
 *
 *   npm run clean && npm run compile
 *   node scripts/exportBeamioStackBaseScanVerifyBundle.mjs
 *   node scripts/exportBeamioStackBaseScanFormJson.mjs
 *
 * 可选 API 验证:
 *   BASESCAN_API_KEY=... npx tsx scripts/verifyBeamioStackBaseScan.ts
 */

import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { AbiCoder, getAddress } from "ethers";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const deploymentsDir = path.join(root, "deployments");

const ENTRY_POINT = getAddress("0x0000000071727De22E5E9d8BAf0edAc6f37da032");
const ADMIN = getAddress("0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1");
const AA_FACTORY = getAddress("0x23a331ee3BD3ab8F8772c7AC4a57fc45867C5B07");
const ORACLE = getAddress("0x77CB8358c5a37aB7190b0A2C7EaA7fEeDCF11008");
const QUOTE_HELPER = getAddress("0xD3f275774831810006d744d32E6b024507C0d374");
/** admin EOA index=0 CREATE2 地址（与 factory.computeSalt + getAddress 一致） */
const SAMPLE_BEAMIO_ACCOUNT = getAddress("0xa75A0e2B5dBa846121DF536ce53Cd920A5CC8483");
const ACCOUNT_LIMIT = 100;

const CONTRACT_NAME_MAP = {
  BeamioFactoryPaymasterV07: [
    "project/src/BeamioAccount/BeamioFactoryPaymasterV07.sol",
    "BeamioFactoryPaymasterV07",
  ],
  BeamioOracle: ["project/src/BeamioUserCard/BeamioOracle.sol", "BeamioOracle"],
  BeamioQuoteHelperV07: [
    "project/src/BeamioUserCard/BeamioQuoteHelperV07.sol",
    "BeamioQuoteHelperV07",
  ],
  BeamioAccount: ["project/src/BeamioAccount/BeamioAccount.sol", "BeamioAccount"],
};

const STACK = [
  {
    exportKey: "BeamioFactoryPaymasterV07",
    label: "BeamioFactoryPaymasterV07 (CREATE2 AA Factory)",
    address: AA_FACTORY,
    constructorTypes: ["uint256", "address"],
    constructorValues: [ACCOUNT_LIMIT, ADMIN],
    deployNote: "Nick CREATE2 @ predicted address; constructor only (chainConfig via initializeChainConfig)",
  },
  {
    exportKey: "BeamioOracle",
    label: "BeamioOracle (CREATE2)",
    address: ORACLE,
    constructorTypes: ["address"],
    constructorValues: [ADMIN],
  },
  {
    exportKey: "BeamioQuoteHelperV07",
    label: "BeamioQuoteHelperV07 (CREATE2)",
    address: QUOTE_HELPER,
    constructorTypes: ["address", "address"],
    constructorValues: [ORACLE, ADMIN],
  },
  {
    exportKey: "BeamioAccount",
    label: "BeamioAccount (CREATE2 instance, admin index=0)",
    address: SAMPLE_BEAMIO_ACCOUNT,
    constructorTypes: ["address"],
    constructorValues: [ENTRY_POINT],
    deployNote:
      "Verify at any deployed BeamioAccount with same initCode. Admin index=0 with current BeamioAccount bytecode: 0xa75A0e2B5dBa846121DF536ce53Cd920A5CC8483",
  },
];

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

function writeMeta(item, contractName, encodedArgs) {
  const metaPath = path.join(deploymentsDir, `base-${item.exportKey}-basescan-verify-meta.txt`);
  const hexNo0x = encodedArgs === "(none)" ? "(none)" : encodedArgs.replace(/^0x/, "");
  const lines = [
    `# BaseScan: ${item.label} @ ${item.address}`,
    "",
    "## Regenerate Standard JSON",
    "",
    "```bash",
    "npm run clean && npm run compile",
    `node scripts/exportStandardJsonFromBuildInfo.mjs ${item.exportKey} --full`,
    "node scripts/exportBeamioStackBaseScanFormJson.mjs",
    "```",
    "",
    "Upload (BaseScan UI 推荐):",
    `  deployments/base-${item.exportKey}-standard-input-FULL-FORM.json`,
    "",
    "Full build-info (备用):",
    `  deployments/base-${item.exportKey}-standard-input-FULL.json`,
    "",
    "## Compiler",
    "",
    "- Version: v0.8.33+commit.64118f21",
    "- viaIR: true",
    "- optimizer.runs: 200",
    "- evmVersion: cancun",
    "",
    "## Contract name (exact)",
    "",
    contractName,
    "",
    "If UI fails, try short name only:",
    contractName.split(":")[1],
    "",
    "## Constructor Args ABI-encoded:",
    "",
    hexNo0x === "(none)" ? "(none)" : hexNo0x,
    "",
  ];
  if (item.deployNote) {
    lines.push("## Deploy note", "", item.deployNote, "");
  }
  fs.writeFileSync(metaPath, lines.join("\n"), "utf-8");
  console.log("  meta:", metaPath);
}

function main() {
  console.log("Export Beamio stack BaseScan FULL JSON + verify meta\n");
  const bundleContracts = [];

  for (const item of STACK) {
    console.log(`\n=== ${item.exportKey} ===`);
    exportFullStandardJson(item.exportKey);
    const contractName = contractNameFor(item.exportKey);
    const encoded = encodeConstructorArgs(item.constructorTypes, item.constructorValues);
    writeMeta(item, contractName, encoded);
    bundleContracts.push({
      exportKey: item.exportKey,
      label: item.label,
      address: item.address,
      contractName,
      jsonRel: jsonRelFor(item.exportKey),
      formJsonRel: `deployments/base-${item.exportKey}-standard-input-FULL-FORM.json`,
      constructorArgs: encoded === "(none)" ? "" : encoded.replace(/^0x/, ""),
    });
  }

  const bundle = {
    network: "base",
    chainId: "8453",
    updatedAt: new Date().toISOString(),
    compiler: "v0.8.33+commit.64118f21",
    contracts: bundleContracts,
  };
  const bundlePath = path.join(deploymentsDir, "base-BeamioStack-verify-bundle.json");
  fs.writeFileSync(bundlePath, JSON.stringify(bundle, null, 2) + "\n", "utf-8");
  console.log("\nBundle:", bundlePath);
  console.log("\nNext: node scripts/exportBeamioStackBaseScanFormJson.mjs");
}

main();
