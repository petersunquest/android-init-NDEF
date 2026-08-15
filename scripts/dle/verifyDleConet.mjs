#!/usr/bin/env node
/**
 * Verify a generated CoNET-DLE deployment record on CoNET Blockscout.
 *
 * Default mode is read-only preflight: compile from the exact artifact
 * build-info, recursively prune the FULL Standard JSON, compile it with the
 * matching local solc, and compare deployed runtime bytecode with eth_getCode.
 * --submit additionally sends the already-preflighted JSON to Blockscout v2 and
 * writes the confirmed v2 self-status back into the generated record.
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { AbiCoder, Interface, JsonRpcProvider, getAddress, isAddress } from "ethers";
import {
  DLE_CHAIN_ID,
  DLE_COMPONENT_BY_KEY,
  DLE_COMPONENTS,
  DLE_RECORD_SCHEMA,
  DLE_SOLC_VERSION,
} from "./deploymentManifest.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const defaultRecord = path.join(root, "deployments/conet-DLE-MVP.json");
const recordPath = process.argv.includes("--record")
  ? path.resolve(root, process.argv[process.argv.indexOf("--record") + 1] ?? "")
  : defaultRecord;
const submit = process.argv.includes("--submit");
const skipCompile = process.argv.includes("--skip-compile");
const rpcUrl = process.env.CONET_RPC_URL || "https://rpc1.conet.network";
const blockscoutUrl = "https://mainnet.conet.network";
const pollAttempts = Number(process.env.CONET_VERIFY_POLL_MAX ?? "90");

function fail(message) {
  throw new Error(`DLE verification failed: ${message}`);
}

function readJson(file) {
  if (!fs.existsSync(file)) fail(`missing generated deployment record: ${file}`);
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function ensureAddress(value, field) {
  if (typeof value !== "string" || !isAddress(value)) fail(`${field} is not an address`);
  return getAddress(value);
}

function runCleanCompile() {
  const clean = spawnSync("npm", ["run", "clean"], { cwd: root, stdio: "inherit" });
  if (clean.status !== 0) fail("npm run clean failed");
  const compile = spawnSync("npm", ["run", "compile"], { cwd: root, stdio: "inherit" });
  if (compile.status !== 0) fail("npm run compile failed");
}

function artifactPathFor(component) {
  return path.join(
    root,
    "artifacts",
    component.sourceKey.replace(/^project\//, ""),
    `${component.contractName}.json`,
  );
}

function sourceFilePath(sourceKey) {
  return path.join(root, sourceKey.replace(/^project\//, ""));
}

function normalizeNpmSourceKey(key) {
  const match = key.match(/^npm\/(@[^/]+\/[^@/]+)@[^/]+\/(.+)$/);
  return match ? `${match[1]}/${match[2]}` : key;
}

function resolveImport(fromKey, specifier, sources) {
  if (sources[specifier]) return specifier;
  if (specifier.startsWith("@")) {
    const direct = Object.keys(sources).find(
      (key) => normalizeNpmSourceKey(key) === specifier,
    );
    if (direct) return direct;
  }
  const fromDir = path.posix.dirname(fromKey.replace(/^project\//, ""));
  const joined = path.posix.normalize(path.posix.join(fromDir, specifier));
  for (const candidate of [`project/${joined}`, joined]) {
    if (sources[candidate]) return candidate;
  }
  return null;
}

function normalizeStandardJson(input) {
  const sources = {};
  for (const [key, value] of Object.entries(input.sources)) {
    const normalized = normalizeNpmSourceKey(key);
    if (sources[normalized]) fail(`normalized Standard JSON source collision: ${normalized}`);
    sources[normalized] = value;
  }
  const settings = { ...input.settings, remappings: [] };
  delete settings.compilationTarget;
  settings.outputSelection = {
    "*": {
      "": ["ast"],
      "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
    },
  };
  return { language: input.language, sources, settings };
}

function pruneFullBuildInfo(fullInput, rootKey) {
  if (!fullInput.sources?.[rootKey]) fail(`FULL build-info is missing ${rootKey}`);
  const keep = new Set();
  const stack = [rootKey];
  while (stack.length > 0) {
    const current = stack.pop();
    if (keep.has(current)) continue;
    const source = fullInput.sources[current];
    if (!source) fail(`unable to resolve required source ${current}`);
    keep.add(current);
    const imports = source.content.matchAll(
      /import\s+(?:[^'"]*\s+from\s+)?["']([^"']+)["']/g,
    );
    for (const match of imports) {
      const resolved = resolveImport(current, match[1], fullInput.sources);
      if (!resolved) fail(`cannot resolve ${match[1]} imported by ${current}`);
      stack.push(resolved);
    }
  }
  const sources = Object.fromEntries([...keep].map((key) => [key, fullInput.sources[key]]));
  return normalizeStandardJson({
    language: fullInput.language,
    sources,
    settings: fullInput.settings,
  });
}

function findSolcBinary(solcLongVersion) {
  const home = os.homedir();
  const candidates = [
    path.join(home, "Library/Caches/hardhat-nodejs/compilers-v3"),
    path.join(home, ".cache/hardhat-nodejs/compilers-v3"),
  ];
  const expected = `v${solcLongVersion}`;
  for (const base of candidates) {
    if (!fs.existsSync(base)) continue;
    for (const platform of fs.readdirSync(base)) {
      const platformPath = path.join(base, platform);
      if (!fs.statSync(platformPath).isDirectory()) continue;
      for (const file of fs.readdirSync(platformPath)) {
        if (file.includes(expected) && file.startsWith("solc-")) {
          return path.join(platformPath, file);
        }
      }
    }
  }
  fail(`matching local solc ${solcLongVersion} was not found in the Hardhat compiler cache`);
}

function bytecodeMatchesAllowingAddressThis(localHex, onchainHex, ...addresses) {
  const local = localHex.replace(/^0x/i, "").toLowerCase();
  const onchain = onchainHex.replace(/^0x/i, "").toLowerCase();
  if (local === onchain) return true;
  if (local.length !== onchain.length) return false;
  const candidates = addresses
    .filter((value) => typeof value === "string" && /^0x[0-9a-fA-F]{40}$/i.test(value))
    .map((value) => value.replace(/^0x/i, "").toLowerCase());
  let otherDiffs = 0;
  for (let i = 0; i < local.length; i += 1) {
    if (local[i] === onchain[i]) continue;
    const matched = candidates.some(
      (address) => local.slice(i, i + 40) === "0".repeat(40) && onchain.slice(i, i + 40) === address,
    );
    if (matched) {
      i += 39;
      continue;
    }
    otherDiffs += 1;
  }
  return otherDiffs === 0;
}

function compileRuntimeWithSolc(standardJson, target, solcPath) {
  const output = execFileSync(solcPath, ["--standard-json"], {
    cwd: root,
    encoding: "utf8",
    input: JSON.stringify(standardJson),
    maxBuffer: 64 * 1024 * 1024,
  });
  const result = JSON.parse(output);
  const errors = (result.errors ?? []).filter((entry) => entry.severity === "error");
  if (errors.length > 0) {
    fail(`${target.key} local solc compilation failed: ${errors[0].formattedMessage ?? errors[0].message}`);
  }
  const runtime = result.contracts?.[target.sourceKey]?.[target.contractName]?.evm?.deployedBytecode?.object;
  if (typeof runtime !== "string" || runtime.length === 0) {
    fail(`${target.key} local solc output has no deployed bytecode`);
  }
  return `0x${runtime}`;
}

function loadAndValidateRecord() {
  const record = readJson(recordPath);
  if (record.schema !== DLE_RECORD_SCHEMA || record.recordState !== "deployed") {
    fail("record must be a generated record with schema conet-dle-deployment-v1 and recordState=deployed");
  }
  if (record.chainId !== DLE_CHAIN_ID) fail(`record chainId must be ${DLE_CHAIN_ID}`);
  if (record.compiler?.solcVersion !== DLE_SOLC_VERSION) {
    fail(`record must declare solc ${DLE_SOLC_VERSION}`);
  }
  if (!Array.isArray(record.components) || !Array.isArray(record.libraries)) {
    fail("record components and libraries must be arrays");
  }

  const byKey = new Map(record.components.map((component) => [component.key, component]));
  if (byKey.size !== record.components.length) fail("record has duplicate component keys");
  for (const expected of DLE_COMPONENTS) {
    const component = byKey.get(expected.key);
    if (!component) fail(`record omits required component ${expected.key}`);
    for (const field of ["kind", "sourceKey", "contractName"]) {
      if (component[field] !== expected[field]) {
        fail(`${expected.key}.${field} differs from the canonical manifest`);
      }
    }
    ensureAddress(component.address, `${expected.key}.address`);
    if (typeof component.deploymentTxHash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(component.deploymentTxHash)) {
      fail(`${expected.key}.deploymentTxHash must be a transaction hash`);
    }
    if (!Number.isInteger(component.deploymentBlock) || component.deploymentBlock < 0) {
      fail(`${expected.key}.deploymentBlock must be a non-negative integer`);
    }
    if (expected.kind === "proxy") {
      if (component.implementationKey !== expected.implementationKey) {
        fail(`${expected.key}.implementationKey differs from the canonical manifest`);
      }
      const implementation = byKey.get(component.implementationKey);
      if (!implementation) fail(`${expected.key} references missing implementation ${component.implementationKey}`);
      if (
        component.initializer?.signature !== expected.initializerSignature ||
        !Array.isArray(component.initializer?.args)
      ) {
        fail(`${expected.key} initializer metadata is incomplete or changed`);
      }
      if (component.initializer.args.some((value) => typeof value === "string" && value.startsWith("$"))) {
        fail(`${expected.key} still contains a template placeholder`);
      }
    }
  }
  if (byKey.size !== DLE_COMPONENTS.length) fail("record includes an unexpected component");
  if (record.libraries.length !== 0) {
    fail("the current DLE MVP artifacts have no linked libraries; a record must not invent library deployments");
  }
  return { record, byKey };
}

function buildProxyConstructorArgs(component, byKey) {
  const implementation = byKey.get(component.implementationKey);
  const initializer = new Interface([`function ${component.initializer.signature}`]).encodeFunctionData(
    "initialize",
    component.initializer.args,
  );
  return AbiCoder.defaultAbiCoder()
    .encode(["address", "bytes"], [ensureAddress(implementation.address, implementation.key), initializer])
    .slice(2);
}

function loadExactBuildInfo(component) {
  const artifactPath = artifactPathFor(component);
  if (!fs.existsSync(artifactPath)) fail(`missing artifact ${artifactPath}`);
  const artifact = readJson(artifactPath);
  if (!artifact.buildInfoId) fail(`${component.key} artifact does not expose buildInfoId`);
  const buildInfoPath = path.join(root, "artifacts/build-info", `${artifact.buildInfoId}.json`);
  if (!fs.existsSync(buildInfoPath)) fail(`${component.key} build-info is missing: ${buildInfoPath}`);
  const buildInfo = readJson(buildInfoPath);
  if (buildInfo.solcVersion !== DLE_SOLC_VERSION || !String(buildInfo.solcLongVersion ?? "").startsWith(`${DLE_SOLC_VERSION}+`)) {
    fail(`${component.key} was not compiled with required solc ${DLE_SOLC_VERSION}`);
  }
  const onDisk = sourceFilePath(component.sourceKey);
  if (!fs.existsSync(onDisk)) fail(`${component.key} source file is missing: ${onDisk}`);
  if (buildInfo.input?.sources?.[component.sourceKey]?.content !== fs.readFileSync(onDisk, "utf8")) {
    fail(`${component.key} build-info source is stale; clean and compile again`);
  }
  if (Object.keys(artifact.linkReferences ?? {}).length !== 0) {
    fail(`${component.key} has linked libraries; add explicit linked-library support before deployment`);
  }
  return { buildInfo, artifact };
}

async function selfStatus(address, expectedName) {
  const response = await fetch(`${blockscoutUrl}/api/v2/smart-contracts/${address}`);
  if (!response.ok) return { verified: false, detail: `HTTP ${response.status}` };
  const data = await response.json();
  const name = typeof data.name === "string" ? data.name : "";
  const sourceLength = String(data.source_code ?? "").length;
  const flagged = Boolean(data.is_verified || data.is_partially_verified);
  const nameMatches = !expectedName || name === expectedName;
  return {
    verified: flagged && nameMatches,
    detail: {
      isVerified: Boolean(data.is_verified),
      isPartiallyVerified: Boolean(data.is_partially_verified),
      sourceLength,
      name,
      verifiedTwin: data.verified_twin_address_hash ?? null,
    },
  };
}

async function submitStandardJson(target, standardJson, compilerVersion, constructorArgs) {
  const form = new FormData();
  form.set("compiler_version", `v${compilerVersion}`);
  form.set("contract_name", `${target.sourceKey}:${target.contractName}`);
  form.set("license_type", "mit");
  form.set("autodetect_constructor_args", constructorArgs ? "false" : "true");
  if (constructorArgs) form.set("constructor_args", constructorArgs);
  form.set(
    "files[0]",
    new Blob([JSON.stringify(standardJson)], { type: "application/json" }),
    "standard-input.json",
  );
  const response = await fetch(
    `${blockscoutUrl}/api/v2/smart-contracts/${target.address}/verification/via/standard-input`,
    { method: "POST", body: form },
  );
  const body = await response.text();
  if (!response.ok && !/already verified/i.test(body)) {
    fail(`${target.key} Blockscout submission failed (HTTP ${response.status}): ${body.slice(0, 500)}`);
  }
}

async function submitLegacyProxy(target, standardJson, compilerVersion, constructorArgs) {
  const params = new URLSearchParams();
  params.set("module", "contract");
  params.set("action", "verifysourcecode");
  params.set("codeformat", "solidity-standard-json-input");
  params.set("contractaddress", target.address);
  params.set("contractname", `${target.sourceKey}:${target.contractName}`);
  params.set("compilerversion", `v${compilerVersion}`);
  params.set("licenseType", "3");
  params.set("constructorArguements", constructorArgs ?? "");
  params.set("sourceCode", JSON.stringify(standardJson));
  const response = await fetch(`${blockscoutUrl}/api`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: params,
  });
  const body = await response.text();
  if (!response.ok && !/already verified/i.test(body)) {
    fail(`${target.key} Blockscout legacy submission failed (HTTP ${response.status}): ${body.slice(0, 500)}`);
  }
}

async function pollSelfStatus(address, expectedName) {
  for (let attempt = 0; attempt < pollAttempts; attempt += 1) {
    const status = await selfStatus(address, expectedName);
    if (status.verified) return status;
    await new Promise((resolve) => setTimeout(resolve, 4000));
  }
  return selfStatus(address, expectedName);
}

async function main() {
  if (!skipCompile) runCleanCompile();
  const { record, byKey } = loadAndValidateRecord();
  const provider = new JsonRpcProvider(rpcUrl);
  const network = await provider.getNetwork();
  if (network.chainId !== BigInt(DLE_CHAIN_ID)) {
    fail(`RPC ${rpcUrl} returned chainId ${network.chainId}, expected ${DLE_CHAIN_ID}`);
  }

  const preflighted = [];
  for (const target of record.components) {
    const { buildInfo } = loadExactBuildInfo(target);
    const standardJson = pruneFullBuildInfo(buildInfo.input, target.sourceKey);
    const outputPath = path.join(root, "deployments", `conet-DLE-${target.key}-verify-buildinfo.json`);
    fs.writeFileSync(outputPath, `${JSON.stringify(standardJson, null, 2)}\n`, "utf8");

    const solcPath = findSolcBinary(buildInfo.solcLongVersion);
    const localRuntime = compileRuntimeWithSolc(standardJson, target, solcPath).toLowerCase();
    const chainRuntime = (await provider.getCode(ensureAddress(target.address, target.key))).toLowerCase();
    if (chainRuntime === "0x") fail(`${target.key} has no deployed code at ${target.address}`);
    const implementationAddress =
      target.kind === "proxy" ? byKey.get(target.implementationKey)?.address : null;
    if (!bytecodeMatchesAllowingAddressThis(localRuntime, chainRuntime, target.address, implementationAddress)) {
      fail(`${target.key} local deployed bytecode does not equal eth_getCode(${target.address})`);
    }
    const constructorArgs = target.kind === "proxy" ? buildProxyConstructorArgs(target, byKey) : null;
    preflighted.push({ target, standardJson, compilerVersion: buildInfo.solcLongVersion, constructorArgs });
    console.log(`✓ bytecode preflight ${target.key} (${Object.keys(standardJson.sources).length} sources)`);
  }

  if (!submit) {
    for (const { target } of preflighted) {
      const status = await selfStatus(target.address, target.contractName);
      console.log(`${status.verified ? "✓" : "!"} Blockscout self-status ${target.key}: ${JSON.stringify(status.detail)}`);
    }
    console.log("Read-only preflight complete. Re-run with --submit to verify every preflighted target.");
    return;
  }

  for (const entry of preflighted) {
    const existing = await selfStatus(entry.target.address, entry.target.contractName);
    if (!existing.verified) {
      try {
        await submitStandardJson(entry.target, entry.standardJson, entry.compilerVersion, entry.constructorArgs);
      } catch (error) {
        if (entry.target.kind !== "proxy") throw error;
        console.warn(`${entry.target.key} v2 submit failed; trying legacy partial-match`);
        await submitLegacyProxy(entry.target, entry.standardJson, entry.compilerVersion, entry.constructorArgs);
      }
    }
    const confirmed = await pollSelfStatus(entry.target.address, entry.target.contractName);
    if (!confirmed.verified) {
      fail(`${entry.target.key} did not reach Blockscout v2 verified/partially-verified self-status`);
    }
    entry.target.verification = {
      verifiedAt: new Date().toISOString(),
      status: confirmed.detail,
      explorer: `${blockscoutUrl}/address/${entry.target.address}#code`,
    };
    console.log(`✓ Blockscout v2 confirmed ${entry.target.key}`);
  }
  record.verification = {
    blockscoutV2: {
      status: "verified",
      completedAt: new Date().toISOString(),
    },
  };
  writeJson(recordPath, record);
  console.log(`Verification record updated: ${recordPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
