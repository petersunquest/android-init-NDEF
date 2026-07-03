#!/usr/bin/env node
/**
 * Export + prune Standard JSON for BUnitAirdrop / BuintRedeemAirdrop (via-IR).
 * Local solc precheck: immutable contracts compare length + non-immutable body;
 * Blockscout fills immutables from constructor_args.
 *
 * 守则: .cursor/rules/conet-mainnet-blockscout-verify.mdc
 *
 * Run:
 *   npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BUnitAirdrop --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BuintRedeemAirdrop --full
 *   node scripts/exportConetBUnitAirdropStackVerifyBuildinfo.mjs
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const deploymentsDir = path.join(root, "deployments");

const SOLC =
  process.env.SOLC ||
  `${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd`;

const TARGETS = [
  {
    key: "BUnitAirdrop",
    fullRel: "deployments/base-BUnitAirdrop-standard-input-FULL.json",
    outRel: "deployments/conet-BUnitAirdrop-verify-buildinfo.json",
    sourceKey: "project/src/b-unit/BUnitAirdrop.sol",
    contractName: "BUnitAirdrop",
    addressKey: "BUnitAirdrop",
    deployJson: "deployments/conet-BUintAirdrop.json",
    addressPath: ["contracts", "BUnitAirdrop", "address"],
  },
  {
    key: "BuintRedeemAirdrop",
    fullRel: "deployments/base-BuintRedeemAirdrop-standard-input-FULL.json",
    outRel: "deployments/conet-BuintRedeemAirdrop-verify-buildinfo.json",
    sourceKey: "project/src/b-unit/BuintRedeemAirdrop.sol",
    contractName: "BuintRedeemAirdrop",
    addressKey: "BuintRedeemAirdrop",
    deployJson: "deployments/conet-BuintRedeemAirdrop.json",
    addressPath: ["contracts", "BuintRedeemAirdrop", "address"],
  },
];

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
  if (!fs.existsSync(fullPath)) throw new Error(`Missing ${fullRel} — run exportStandardJsonFromBuildInfo.mjs --full first`);
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
  input.settings.remappings = [];
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
  return (data.result || "0x").slice(2).toLowerCase();
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
  const c = out.contracts[sourceKey][contractName];
  return {
    deployed: c.evm.deployedBytecode.object.toLowerCase(),
    immutableReferences: c.evm.deployedBytecode.immutableReferences || {},
  };
}

/** Zero-out immutable slots in chain bytecode for comparison with unlinked solc output. */
function maskImmutables(bytecodeHex, immutableReferences) {
  const buf = Buffer.from(bytecodeHex, "hex");
  for (const refs of Object.values(immutableReferences)) {
    for (const { start, length } of refs) {
      buf.fill(0, start, start + length);
    }
  }
  return buf.toString("hex");
}

function readAddress(target) {
  const p = path.join(root, target.deployJson);
  const data = JSON.parse(fs.readFileSync(p, "utf-8"));
  let cur = data;
  for (const k of target.addressPath) cur = cur?.[k];
  if (!cur) throw new Error(`Missing address in ${target.deployJson}`);
  return cur;
}

function main() {
  if (!fs.existsSync(SOLC)) {
    throw new Error(`solc not found: ${SOLC}`);
  }

  for (const t of TARGETS) {
    console.log(`\n=== ${t.key} ===`);
    const input = pruneFullJson(t.fullRel, t.sourceKey);
    const outPath = path.join(root, t.outRel);
    const addr = readAddress(t);
    const onChain = chainCode(addr);
    if (!onChain || onChain === "0x") throw new Error(`no code at ${addr}`);

    const { deployed, immutableReferences } = compileDeployed(input, t.sourceKey, t.contractName);
    const localMasked = maskImmutables(deployed, immutableReferences);
    const chainMasked = maskImmutables(onChain, immutableReferences);

    console.log("  address:", addr);
    console.log("  sources:", Object.keys(input.sources).length);
    console.log("  local deployed bytes:", deployed.length / 2);
    console.log("  chain deployed bytes:", onChain.length / 2);
    console.log("  immutable slots:", Object.keys(immutableReferences).length);

    if (localMasked.length !== chainMasked.length) {
      throw new Error(
        `bytecode length mismatch after immutable mask: local=${localMasked.length / 2} chain=${chainMasked.length / 2}`,
      );
    }
    if (localMasked !== chainMasked) {
      let first = -1;
      for (let i = 0; i < localMasked.length; i += 2) {
        if (localMasked.slice(i, i + 2) !== chainMasked.slice(i, i + 2)) {
          first = i / 2;
          break;
        }
      }
      throw new Error(`bytecode mismatch after immutable mask at byte ${first}`);
    }
    console.log("  ✅ local solc matches chain (immutables masked)");

    fs.writeFileSync(outPath, JSON.stringify(input) + "\n");
    console.log("  wrote", t.outRel, `(${(fs.statSync(outPath).size / 1024).toFixed(1)} KB)`);
  }
  console.log("\n✅ verify-buildinfo ready");
}

main();
