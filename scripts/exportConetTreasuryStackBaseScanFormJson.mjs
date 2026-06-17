#!/usr/bin/env node
/**
 * Generate BaseScan UI-friendly Standard JSON files for the ConetTreasury stack.
 *
 * These files keep the same full build-info sources/settings used by the
 * BeamioUserCard verification flow, but narrow outputSelection to exactly one
 * contract. This is useful when the BaseScan form does not expose a reliable
 * Contract Name field and otherwise compiles target ''.
 *
 * Run after:
 *   npm run clean && npm run compile
 *   node scripts/exportConetTreasuryStackStandardJson.mjs
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const deploymentsDir = path.join(root, "deployments");
const bundlePath = path.join(deploymentsDir, "base-ConetTreasuryStack-verify-bundle.json");

if (!fs.existsSync(bundlePath)) {
  throw new Error(
    "Missing deployments/base-ConetTreasuryStack-verify-bundle.json. Run node scripts/exportConetTreasuryStackStandardJson.mjs first."
  );
}

const bundle = JSON.parse(fs.readFileSync(bundlePath, "utf-8"));
const guide = [
  "BaseScan UI form verification files",
  "",
  "These JSON files are legal Solidity Standard JSON input.",
  "They keep the BeamioUserCard-style FULL build-info settings, but recursively prune sources to exactly what is imported.",
  "This ensures the JSON files are extremely small (under 100 KB), compile instantly, and never hit BaseScan limits.",
  "",
];

// Normalize path helper (e.g. resolve "./foo.sol" relative to "project/src/b-unit")
function resolveImportPath(currentKey, importPath) {
  if (importPath.startsWith("@openzeppelin/")) {
    return importPath;
  }
  const dir = currentKey.substring(0, currentKey.lastIndexOf("/"));
  const parts = (dir + "/" + importPath).split("/");
  const resolvedParts = [];
  for (const part of parts) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      resolvedParts.pop();
    } else {
      resolvedParts.push(part);
    }
  }
  return resolvedParts.join("/");
}

function extractImports(solidityCode) {
  const imports = [];
  const regex = /import\s+(?:{[^}]+}\s+from\s+)?["']([^"']+)["']/g;
  let match;
  while ((match = regex.exec(solidityCode)) !== null) {
    imports.push(match[1]);
  }
  return imports;
}

function getRecursiveDependencies(rootKey, allSources) {
  const visited = new Set();
  const queue = [rootKey];
  while (queue.length > 0) {
    const key = queue.shift();
    if (visited.has(key)) continue;
    visited.add(key);
    const src = allSources[key];
    if (!src) {
      console.warn(`警告: source file ${key} not found in input sources.`);
      continue;
    }
    const imports = extractImports(src.content);
    for (const imp of imports) {
      const resolved = resolveImportPath(key, imp);
      queue.push(resolved);
    }
  }
  return Array.from(visited);
}

for (const item of bundle.contracts ?? []) {
  const fullPath = path.join(root, item.jsonRel);
  if (!fs.existsSync(fullPath)) {
    throw new Error(`Missing FULL JSON: ${item.jsonRel}`);
  }

  const lastColon = item.contractName.lastIndexOf(":");
  if (lastColon <= 0) {
    throw new Error(`Invalid contractName in bundle: ${item.contractName}`);
  }
  const sourceKey = item.contractName.slice(0, lastColon);
  const contractName = item.contractName.slice(lastColon + 1);

  const input = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
  if (input.settings?.compilationTarget) {
    delete input.settings.compilationTarget;
  }
  if (!input.sources?.[sourceKey]) {
    throw new Error(`${item.jsonRel} does not contain source ${sourceKey}`);
  }

  // Prune sources recursively
  console.log(`Pruning sources for ${item.exportKey}...`);
  const dependentKeys = getRecursiveDependencies(sourceKey, input.sources);
  const prunedSources = {};
  for (const k of dependentKeys) {
    if (input.sources[k]) {
      prunedSources[k] = input.sources[k];
    }
  }
  input.sources = prunedSources;
  console.log(`  Reduced sources from ${Object.keys(input.sources).length} to ${dependentKeys.length}`);

  input.settings ??= {};
  input.settings.outputSelection = {
    "*": {
      "": [
        "ast"
      ],
      "*": [
        "abi",
        "evm.bytecode",
        "evm.deployedBytecode",
        "evm.methodIdentifiers",
        "metadata"
      ]
    }
  };

  const outRel = `deployments/base-${item.exportKey}-standard-input-FULL-FORM.json`;
  const outPath = path.join(root, outRel);
  const json = JSON.stringify(input, null, 2);
  fs.writeFileSync(outPath, json, "utf-8");

  const sizeKb = (fs.statSync(outPath).size / 1024).toFixed(1);
  console.log(`${outRel} (${sizeKb} KB) -> ${item.contractName}`);

  guide.push(
    `## ${item.exportKey}`,
    `Address: ${item.address}`,
    `Upload JSON: ${outRel} (${sizeKb} KB)`,
    `Contract Name: ${item.contractName}`,
    `Constructor Arguments (no 0x): ${String(item.constructorArgs ?? "").replace(/^0x/, "") || "(none)"}`,
    ""
  );
}

const guidePath = path.join(deploymentsDir, "base-ConetTreasuryStack-basescan-form-guide.txt");
fs.writeFileSync(guidePath, guide.join("\n"), "utf-8");
console.log(`\nGuide: ${guidePath}`);
