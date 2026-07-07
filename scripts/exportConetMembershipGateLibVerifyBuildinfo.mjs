#!/usr/bin/env node
/**
 * Prune FULL Standard JSON + local deployedBytecode precheck for MembershipGateLib.
 *
 * Run after:
 *   npm run clean && npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardMembershipGateLib --full
 *   node scripts/exportConetMembershipGateLibVerifyBuildinfo.mjs
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

function pruneFullJson(fullRel, sourceKey) {
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
const libAddress = addr.beamioUserCardMembershipGateLib;
if (!libAddress) throw new Error("beamioUserCardMembershipGateLib missing in conet-addresses.json");

const sourceKey = "project/src/BeamioUserCard/BeamioUserCardMembershipGateLib.sol";
const contractName = "BeamioUserCardMembershipGateLib";
const fullRel = "deployments/base-BeamioUserCardMembershipGateLib-standard-input-FULL.json";
const outRel = "deployments/conet-MembershipGateLib-verify-buildinfo.json";

console.log("MembershipGateLib verify JSON…");
const std = pruneFullJson(fullRel, sourceKey);
const outPath = path.join(root, outRel);
fs.writeFileSync(outPath, JSON.stringify(std), "utf-8");
const kb = (fs.statSync(outPath).size / 1024).toFixed(1);
console.log(`  wrote ${outRel} (${kb} KB, ${Object.keys(std.sources).length} sources)`);

const local = compileDeployed(std, sourceKey, contractName);
const chain = chainCode(libAddress);
if (local !== chain) {
  throw new Error(`bytecode mismatch local=${local.length} chain=${chain.length}`);
}
console.log(`  ✅ bytecode match @ ${libAddress}`);
console.log("\nNext:");
console.log("  CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyConetMembershipGateLibOnScan.ts");
