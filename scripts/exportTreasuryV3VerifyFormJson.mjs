#!/usr/bin/env node
/**
 * Convert a V3 FULL Standard JSON into a compact recursive-import FORM file.
 * npm source keys are normalized because Blockscout/BaseScan do not resolve
 * Hardhat's versioned npm remappings consistently.
 */
import fs from "node:fs";
import path from "node:path";

const input = process.argv[2];
if (!input) {
  console.error("Usage: node scripts/exportTreasuryV3VerifyFormJson.mjs <FULL.json>");
  process.exit(1);
}

const fullPath = path.resolve(input);
const json = JSON.parse(fs.readFileSync(fullPath, "utf8"));
const normalizeKey = (key) =>
  key
    .replace(/^npm\/@openzeppelin\/contracts-upgradeable@[^/]+\//, "@openzeppelin/contracts-upgradeable/")
    .replace(/^npm\/@openzeppelin\/contracts@[^/]+\//, "@openzeppelin/contracts/");

const normalizedSources = {};
for (const [key, value] of Object.entries(json.sources ?? {})) {
  normalizedSources[normalizeKey(key)] = value;
}

const rootSuffix = fullPath.includes("CanonicalERC20V3")
  ? "src/b-unit/TreasuryCanonicalERC20V3.sol"
  : "src/b-unit/TreasuryBridgeV3.sol";
const root = Object.keys(normalizedSources).find((key) => key.endsWith(rootSuffix));
if (!root) throw new Error("Could not identify a Treasury V3 source in FULL JSON");

const resolveImport = (from, specifier) => {
  if (specifier.startsWith("@openzeppelin/")) return specifier;
  if (specifier.startsWith(".")) {
    const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(from), specifier));
    return resolved.replace(/^\.\//, "");
  }
  return specifier;
};

const selected = new Set();
const visit = (key) => {
  if (selected.has(key)) return;
  const source = normalizedSources[key];
  if (!source) throw new Error(`Missing recursive dependency ${key}`);
  selected.add(key);
  const imports = [...source.content.matchAll(/import\s+(?:[^"']+from\s+)?["']([^"']+)["'];/g)];
  for (const match of imports) visit(resolveImport(key, match[1]));
};
visit(root);

const output = {
  ...json,
  settings: {
    ...json.settings,
    remappings: [],
    outputSelection: {
      "*": {
        "": ["ast"],
        "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
      },
    },
  },
  sources: Object.fromEntries([...selected].map((key) => [key, normalizedSources[key]])),
};
delete output.settings.compilationTarget;

const outputPath = fullPath.replace(/-FULL\.json$/, "-FULL-FORM.json");
fs.writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`);
console.log(`Exported ${selected.size} sources to ${outputPath}`);
