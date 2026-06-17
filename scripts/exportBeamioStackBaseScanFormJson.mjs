#!/usr/bin/env node
/**
 * 为 Beamio AA + Oracle 栈生成 BaseScan UI 友好 FULL-FORM JSON（递归剪枝）。
 * 前置: node scripts/exportBeamioStackBaseScanVerifyBundle.mjs
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const deploymentsDir = path.join(root, "deployments");
const bundlePath = path.join(deploymentsDir, "base-BeamioStack-verify-bundle.json");

if (!fs.existsSync(bundlePath)) {
  throw new Error("Missing base-BeamioStack-verify-bundle.json; run exportBeamioStackBaseScanVerifyBundle.mjs first");
}

const bundle = JSON.parse(fs.readFileSync(bundlePath, "utf-8"));
const guide = [
  "BaseScan UI — Beamio AA + Oracle stack verification",
  "",
  "Use FULL-FORM JSON files (pruned, UI-safe outputSelection).",
  "",
];

function resolveImportPath(currentKey, importPath) {
  if (importPath.startsWith("@openzeppelin/")) return importPath;
  const dir = currentKey.substring(0, currentKey.lastIndexOf("/"));
  const parts = (dir + "/" + importPath).split("/");
  const resolvedParts = [];
  for (const part of parts) {
    if (part === "" || part === ".") continue;
    if (part === "..") resolvedParts.pop();
    else resolvedParts.push(part);
  }
  return resolvedParts.join("/");
}

function extractImports(solidityCode) {
  const imports = [];
  const regex = /import\s+(?:{[^}]+}\s+from\s+)?["']([^"']+)["']/g;
  let match;
  while ((match = regex.exec(solidityCode)) !== null) imports.push(match[1]);
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
      console.warn(`警告: source ${key} not in input`);
      continue;
    }
    for (const imp of extractImports(src.content)) {
      queue.push(resolveImportPath(key, imp));
    }
  }
  return Array.from(visited);
}

for (const item of bundle.contracts ?? []) {
  const fullPath = path.join(root, item.jsonRel);
  if (!fs.existsSync(fullPath)) throw new Error(`Missing ${item.jsonRel}`);

  const lastColon = item.contractName.lastIndexOf(":");
  const sourceKey = item.contractName.slice(0, lastColon);
  const input = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
  if (input.settings?.compilationTarget) delete input.settings.compilationTarget;
  if (!input.sources?.[sourceKey]) throw new Error(`${item.jsonRel} missing ${sourceKey}`);

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

  const outRel = item.formJsonRel.replace(/^deployments\//, "");
  const outPath = path.join(deploymentsDir, outRel);
  fs.writeFileSync(outPath, JSON.stringify(input, null, 2) + "\n", "utf-8");
  const sizeKb = (fs.statSync(outPath).size / 1024).toFixed(1);
  console.log(`${outRel} (${sizeKb} KB)`);

  guide.push(
    `## ${item.exportKey}`,
    `Address: ${item.address}`,
    `Upload: deployments/${outRel} (${sizeKb} KB)`,
    `Contract Name: ${item.contractName}`,
    `Constructor (no 0x): ${item.constructorArgs || "(none)"}`,
    ""
  );
}

const guidePath = path.join(deploymentsDir, "base-BeamioStack-basescan-form-guide.txt");
fs.writeFileSync(guidePath, guide.join("\n"), "utf-8");
console.log(`\nGuide: ${guidePath}`);
