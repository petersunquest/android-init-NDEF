#!/usr/bin/env node
/**
 * Validate the address-free CoNET-DLE deployment template and deployment order.
 *
 * This is deliberately a local-only dry run. It never constructs a signer,
 * connects to an RPC endpoint, submits a transaction, or writes a deployment
 * record. A real deployment must replace every symbolic value in a copy of the
 * template and record every receipt before verification is allowed.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import {
  DLE_CHAIN_ID,
  DLE_COMPONENT_BY_KEY,
  DLE_COMPONENTS,
  DLE_IMPLEMENTATION_ORDER,
  DLE_PROXY_ORDER,
  DLE_RECORD_SCHEMA,
  DLE_SOLC_VERSION,
} from "./deploymentManifest.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const defaultRecord = path.join(root, "deployments/conet-DLE-MVP.template.json");
const recordPath = process.argv.includes("--record")
  ? path.resolve(root, process.argv[process.argv.indexOf("--record") + 1] ?? "")
  : defaultRecord;
const skipCompile = process.argv.includes("--skip-compile");

function fail(message) {
  throw new Error(`DLE dry-run failed: ${message}`);
}

function readJson(file) {
  if (!fs.existsSync(file)) fail(`missing record: ${file}`);
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function assertTemplateValue(value, field) {
  if (typeof value !== "string" || !value.startsWith("$")) {
    fail(`${field} must remain an explicit $PLACEHOLDER in a dry-run template`);
  }
}

function artifactPathFor(component) {
  const sourcePath = component.sourceKey.replace(/^project\//, "");
  return path.join(root, "artifacts", sourcePath, `${component.contractName}.json`);
}

function runCompile() {
  const result = spawnSync("npm", ["run", "clean"], {
    cwd: root,
    stdio: "inherit",
  });
  if (result.status !== 0) fail("npm run clean failed");
  const compile = spawnSync("npm", ["run", "compile"], {
    cwd: root,
    stdio: "inherit",
  });
  if (compile.status !== 0) fail("npm run compile failed");
}

function verifyArtifacts(record) {
  const seen = new Set();
  for (const component of record.components) {
    const expected = DLE_COMPONENT_BY_KEY[component.key];
    if (!expected) fail(`unexpected component ${component.key}`);
    if (seen.has(component.key)) fail(`duplicate component ${component.key}`);
    seen.add(component.key);
    for (const field of ["kind", "sourceKey", "contractName"]) {
      if (component[field] !== expected[field]) {
        fail(`${component.key}.${field} differs from the canonical manifest`);
      }
    }
    const artifactPath = artifactPathFor(component);
    if (!fs.existsSync(artifactPath)) fail(`missing compiled artifact ${artifactPath}`);
    const artifact = readJson(artifactPath);
    if (typeof artifact.bytecode !== "string" || artifact.bytecode === "0x") {
      fail(`${component.key} has no deployable bytecode`);
    }
    const linkReferences = artifact.linkReferences ?? {};
    if (Object.keys(linkReferences).length > 0) {
      fail(
        `${component.key} has external library links; add their exact deployment records before a DLE deployment`,
      );
    }
  }
  for (const component of DLE_COMPONENTS) {
    if (!seen.has(component.key)) fail(`missing canonical component ${component.key}`);
  }
}

function verifyTemplate(record) {
  if (record.schema !== DLE_RECORD_SCHEMA) fail("unexpected schema");
  if (record.recordState !== "template") fail("dry run accepts only recordState=template");
  if (record.chainId !== DLE_CHAIN_ID) fail(`chainId must be ${DLE_CHAIN_ID}`);
  if (record.compiler?.solcVersion !== DLE_SOLC_VERSION) {
    fail(`compiler.solcVersion must be ${DLE_SOLC_VERSION}`);
  }
  if (!Array.isArray(record.components) || !Array.isArray(record.libraries)) {
    fail("components and libraries must be arrays");
  }
  if (record.libraries.length !== 0) {
    fail("the current DLE MVP has no linked Solidity libraries; do not invent library addresses");
  }
  for (const [field, value] of Object.entries(record.configuration ?? {})) {
    assertTemplateValue(value, `configuration.${field}`);
  }
  for (const component of record.components) {
    if (component.address !== null || component.deploymentTxHash !== null || component.deploymentBlock !== null) {
      fail(`${component.key} must not contain a deployment address or receipt in a template`);
    }
    if (component.kind === "proxy") {
      if (!component.initializer) fail(`${component.key} is missing initializer metadata`);
      if (component.initializer.signature !== DLE_COMPONENT_BY_KEY[component.key].initializerSignature) {
        fail(`${component.key} initializer signature differs from manifest`);
      }
      for (const [index, value] of component.initializer.args.entries()) {
        assertTemplateValue(value, `${component.key}.initializer.args[${index}]`);
      }
    }
  }
}

function main() {
  if (!skipCompile) runCompile();
  const record = readJson(recordPath);
  verifyTemplate(record);
  verifyArtifacts(record);

  console.log("DLE local deployment dry-run passed.");
  console.log(`Chain: CoNET ${DLE_CHAIN_ID}; compiler: solc ${DLE_SOLC_VERSION}`);
  console.log("Implementation deployment order:");
  for (const key of DLE_IMPLEMENTATION_ORDER) console.log(`  - ${key}`);
  console.log("Proxy deployment order (each must initialize atomically):");
  for (const key of DLE_PROXY_ORDER) console.log(`  - ${key}`);
  console.log(
    "No RPC request, signer, deployment record write, transaction, or Blockscout submission was performed.",
  );
}

main();
