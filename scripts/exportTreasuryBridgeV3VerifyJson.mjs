#!/usr/bin/env node
/**
 * Export TreasuryBridgeV3 Standard JSON that matches the Hardhat artifact
 * (correct buildInfoId — not the largest build-info unit).
 *
 *   node scripts/exportTreasuryBridgeV3VerifyJson.mjs
 * → deployments/base-TreasuryBridgeV3-standard-input-VERIFY.json
 * → deployments/base-TreasuryBridgeV3-standard-input-VERIFY-FORM.json
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ARTIFACT = path.join(ROOT, "artifacts/src/b-unit/TreasuryBridgeV3.sol/TreasuryBridgeV3.json");
const SOURCE_KEY = "project/src/b-unit/TreasuryBridgeV3.sol";
const CONTRACT = "TreasuryBridgeV3";
const COMPILER = "v0.8.35+commit.47b9dedd";

function normalizeNpmKeys(input) {
  const sources = {};
  for (const [key, value] of Object.entries(input.sources ?? {})) {
    const nk = key
      .replace(/^npm\/@openzeppelin\/contracts-upgradeable@[^/]+\//, "@openzeppelin/contracts-upgradeable/")
      .replace(/^npm\/@openzeppelin\/contracts@[^/]+\//, "@openzeppelin/contracts/");
    sources[nk] = value;
  }
  const settings = {
    ...input.settings,
    remappings: [],
    outputSelection: {
      "*": {
        "": ["ast"],
        "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
      },
    },
  };
  delete settings.compilationTarget;
  return { language: input.language, sources, settings };
}

function prune(input, root) {
  const selected = new Set();
  const resolve = (from, specifier) => {
    if (specifier.startsWith("@openzeppelin/")) return specifier;
    if (specifier.startsWith(".")) {
      return path.posix.normalize(path.posix.join(path.posix.dirname(from), specifier)).replace(/^\.\//, "");
    }
    return specifier;
  };
  const visit = (key) => {
    if (selected.has(key)) return;
    const source = input.sources[key];
    if (!source) throw new Error(`Missing dependency ${key}`);
    selected.add(key);
    for (const match of source.content.matchAll(/import\s+(?:[^"']+from\s+)?["']([^"']+)["'];/g)) {
      visit(resolve(key, match[1]));
    }
  };
  visit(root);
  return {
    language: input.language,
    settings: input.settings,
    sources: Object.fromEntries([...selected].map((k) => [k, input.sources[k]])),
  };
}

function solcCompile(jsonPath) {
  const solc = path.join(
    homedir(),
    "Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64",
    `solc-macosx-amd64-${COMPILER}`,
  );
  if (!fs.existsSync(solc)) throw new Error(`solc missing: ${solc}`);
  const r = spawnSync(solc, ["--standard-json", jsonPath], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.status !== 0) throw new Error(r.stderr || "solc failed");
  const out = JSON.parse(r.stdout);
  const fatal = (out.errors ?? []).filter((e) => e.severity === "error");
  if (fatal.length) throw new Error(fatal.map((e) => e.formattedMessage).join("\n"));
  const obj = out.contracts?.[SOURCE_KEY]?.[CONTRACT]?.evm?.deployedBytecode?.object;
  if (!obj) throw new Error("No deployedBytecode in solc output");
  return obj.replace(/^0x/, "").toLowerCase();
}

const art = JSON.parse(fs.readFileSync(ARTIFACT, "utf8"));
const biPath = path.join(ROOT, "artifacts/build-info", `${art.buildInfoId}.json`);
if (!fs.existsSync(biPath)) throw new Error(`build-info missing: ${biPath}`);
const bi = JSON.parse(fs.readFileSync(biPath, "utf8"));
const normalized = normalizeNpmKeys(bi.input);
const form = prune(normalized, SOURCE_KEY);

const fullOut = path.join(ROOT, "deployments", "base-TreasuryBridgeV3-standard-input-VERIFY.json");
const formOut = path.join(ROOT, "deployments", "base-TreasuryBridgeV3-standard-input-VERIFY-FORM.json");
fs.writeFileSync(fullOut, `${JSON.stringify(normalized, null, 2)}\n`);
fs.writeFileSync(formOut, `${JSON.stringify(form, null, 2)}\n`);

const artBc = String(art.deployedBytecode).replace(/^0x/, "").toLowerCase();
const compiled = solcCompile(formOut);
if (compiled !== artBc) {
  throw new Error(`Bytecode mismatch after export: solc=${compiled.length / 2} art=${artBc.length / 2}`);
}

console.log(JSON.stringify({
  buildInfoId: art.buildInfoId,
  sources: Object.keys(form.sources).length,
  bytes: artBc.length / 2,
  fullOut,
  formOut,
}, null, 2));
