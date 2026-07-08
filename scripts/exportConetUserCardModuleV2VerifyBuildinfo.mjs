#!/usr/bin/env node
/**
 * Regenerate deployments/conet-*-verify-buildinfo.json from FULL build-info export.
 * Prunes sources recursively (via-IR safe) and injects ChargeReward library links.
 *
 * 守则: .cursor/rules/conet-mainnet-blockscout-verify.mdc
 *
 * Run after:
 *   npm run clean && npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardIssuedNftModuleV2 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardChargeRewardModuleV2 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardAdminStatsQueryModuleV2 --full
 *   node scripts/exportConetUserCardModuleV2VerifyBuildinfo.mjs
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const deploymentsDir = path.join(root, "deployments");
const addressesPath = path.join(deploymentsDir, "conet-addresses.json");

const SOLC =
  process.env.SOLC ||
  `${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd`;

function resolveImportPath(currentKey, importPath) {
  if (importPath.startsWith("@openzeppelin/")) return importPath;
  const dir = currentKey.substring(0, currentKey.lastIndexOf("/"));
  const parts = `${dir}/${importPath}`.split("/");
  const resolved = [];
  for (const part of parts) {
    if (part === "" || part === ".") continue;
    if (part === "..") resolved.pop();
    else resolved.push(part);
  }
  return resolved.join("/");
}

function extractImports(code) {
  const imports = [];
  const re = /import\s+(?:{[^}]+}\s+from\s+)?["']([^"']+)["']/g;
  let m;
  while ((m = re.exec(code)) !== null) imports.push(m[1]);
  return imports;
}

function getRecursiveDependencies(rootKey, allSources) {
  const visited = new Set();
  const queue = [rootKey];
  while (queue.length) {
    const key = queue.shift();
    if (visited.has(key)) continue;
    visited.add(key);
    const src = allSources[key];
    if (!src) {
      console.warn(`  warn: missing source ${key}`);
      continue;
    }
    for (const imp of extractImports(src.content)) {
      queue.push(resolveImportPath(key, imp));
    }
  }
  return [...visited];
}

function pruneFullJson(fullRel, sourceKey, libraryLinks) {
  const fullPath = path.join(root, fullRel);
  if (!fs.existsSync(fullPath)) throw new Error(`Missing ${fullRel}`);
  const input = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
  delete input.settings?.compilationTarget;
  const deps = getRecursiveDependencies(sourceKey, input.sources);
  const pruned = {};
  for (const k of deps) {
    if (input.sources[k]) pruned[k] = input.sources[k];
  }
  input.sources = pruned;
  input.settings ??= {};
  input.settings.outputSelection = {
    "*": {
      "": ["ast"],
      "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
    },
  };
  if (libraryLinks) input.settings.libraries = libraryLinks;
  return input;
}

function chainCode(addr) {
  const res = spawnSync(
    "curl",
    [
      "-s",
      "https://publicrpc.conet.network",
      "-H",
      "content-type:application/json",
      "-d",
      JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [addr, "latest"] }),
    ],
    { encoding: "utf-8" },
  );
  const data = JSON.parse(res.stdout);
  return data.result.slice(2).toLowerCase();
}

function compileDeployed(stdJson, sourceKey, contractName) {
  const res = spawnSync(SOLC, ["--standard-json", "-"], {
    input: JSON.stringify(stdJson),
    encoding: "utf-8",
    maxBuffer: 64 * 1024 * 1024,
  });
  const out = JSON.parse(res.stdout);
  const errs = (out.errors ?? []).filter((e) => e.severity === "error");
  if (errs.length) throw new Error(errs.map((e) => e.formattedMessage ?? e.message).join("\n"));
  return out.contracts[sourceKey][contractName].evm.deployedBytecode.object.toLowerCase();
}

const addr = JSON.parse(fs.readFileSync(addressesPath, "utf-8"));
const libLinks = {
  "project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol": {
    BeamioUserCardReferrerLib: addr.beamioUserCardReferrerLib,
  },
  "project/src/BeamioUserCard/BeamioUserCardTransferLib.sol": {
    BeamioUserCardTransferLib: addr.beamioUserCardTransferLib,
  },
};

const targets = [
  {
    label: "IssuedNftModuleV2",
    fullRel: "deployments/base-BeamioUserCardIssuedNftModuleV2-standard-input-FULL.json",
    outRel: "deployments/conet-IssuedNftModuleV2-verify-buildinfo.json",
    sourceKey: "project/src/BeamioUserCard/IssuedNftModuleV2.sol",
    contractName: "BeamioUserCardIssuedNftModuleV2",
    address: addr.issuedNftModule,
  },
  {
    label: "ChargeRewardModuleV2",
    fullRel: "deployments/base-BeamioUserCardChargeRewardModuleV2-standard-input-FULL.json",
    outRel: "deployments/conet-ChargeRewardModuleV2-verify-buildinfo.json",
    sourceKey: "project/src/BeamioUserCard/ChargeRewardModuleV2.sol",
    contractName: "BeamioUserCardChargeRewardModuleV2",
    address: addr.chargeRewardModule,
    libraryLinks: libLinks,
  },
  {
    label: "AdminStatsQueryModuleV2",
    fullRel: "deployments/base-BeamioUserCardAdminStatsQueryModuleV2-standard-input-FULL.json",
    outRel: "deployments/conet-AdminStatsQueryModuleV2-verify-buildinfo.json",
    sourceKey: "project/src/BeamioUserCard/AdminStatsQueryModuleV2.sol",
    contractName: "BeamioUserCardAdminStatsQueryModuleV2",
    address: addr.adminStatsQueryModule,
  },
];

for (const t of targets) {
  console.log(`\n${t.label}…`);
  const std = pruneFullJson(t.fullRel, t.sourceKey, t.libraryLinks);
  const outPath = path.join(root, t.outRel);
  fs.writeFileSync(outPath, JSON.stringify(std), "utf-8");
  const kb = (fs.statSync(outPath).size / 1024).toFixed(1);
  console.log(`  wrote ${t.outRel} (${kb} KB, ${Object.keys(std.sources).length} sources)`);
  const local = compileDeployed(std, t.sourceKey, t.contractName);
  const chain = chainCode(t.address);
  if (local !== chain) {
    throw new Error(`${t.label} bytecode mismatch local=${local.length} chain=${chain.length}`);
  }
  console.log(`  ✅ bytecode match @ ${t.address}`);
}

console.log("\nDone. Next:");
console.log(
  "  CONET_VERIFY_POLL_MAX=180 CONET_VERIFY_ONLY=BeamioUserCardIssuedNftModuleV2,BeamioUserCardChargeRewardModuleV2,BeamioUserCardAdminStatsQueryModuleV2 npx tsx scripts/verifyConetUserCardModulesOnScan.ts",
);
