#!/usr/bin/env node
/**
 * 剪枝 FULL BeamioUserCard build-info + 注入 CoNET library links + 链上 deployedBytecode 预检。
 *
 * 前置:
 *   npm run clean && npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCard --full
 *
 * 用法:
 *   CONET_USER_CARD_ADDRESS=0x703Ca8... node scripts/exportConetBeamioUserCardVerifyBuildinfo.mjs
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const deploymentsDir = path.join(root, "deployments");
const addressesPath = path.join(deploymentsDir, "conet-addresses.json");

const CARD = process.env.CONET_USER_CARD_ADDRESS;
if (!CARD) {
  console.error("请设置 CONET_USER_CARD_ADDRESS");
  process.exit(1);
}

const SOLC =
  process.env.SOLC ||
  `${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd`;

const SOURCE_KEY = "project/src/BeamioUserCard/BeamioUserCard.sol";
const CONTRACT_NAME = "BeamioUserCard";
const FULL_REL = "deployments/base-BeamioUserCard-standard-input-FULL.json";
const outRel = `deployments/conet-BeamioUserCard-${CARD.slice(2, 10)}-verify-buildinfo.json`;

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

function loadLibLinks() {
  const addr = JSON.parse(fs.readFileSync(addressesPath, "utf-8"));
  return {
    "project/src/BeamioUserCard/BeamioUserCardAdminGatewayLib.sol": {
      BeamioUserCardAdminGatewayLib: addr.beamioUserCardAdminGatewayLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardFaucetGatewayLib.sol": {
      BeamioUserCardFaucetGatewayLib: addr.beamioUserCardFaucetGatewayLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardFormattingLib.sol": {
      BeamioUserCardFormattingLib: addr.beamioUserCardFormattingLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardGatewayMintLib.sol": {
      BeamioUserCardGatewayMintLib: addr.beamioUserCardGatewayMintLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardGovernanceLib.sol": {
      BeamioUserCardGovernanceLib: addr.beamioUserCardGovernanceLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardIssuedNftGatewayLib.sol": {
      BeamioUserCardIssuedNftGatewayLib: addr.beamioUserCardIssuedNftGatewayLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardModuleRouterLib.sol": {
      BeamioUserCardModuleRouterLib: addr.beamioUserCardModuleRouterLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardRedeemGatewayLib.sol": {
      BeamioUserCardRedeemGatewayLib: addr.beamioUserCardRedeemGatewayLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol": {
      BeamioUserCardReferrerLib: addr.beamioUserCardReferrerLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardTransferLib.sol": {
      BeamioUserCardTransferLib: addr.beamioUserCardTransferLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardUpdateLib.sol": {
      BeamioUserCardUpdateLib: addr.beamioUserCardUpdateLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardViewsLib.sol": {
      BeamioUserCardViewsLib: addr.beamioUserCardViewsLib,
    },
    "project/src/BeamioUserCard/BeamioUserCardMembershipGateLib.sol": {
      BeamioUserCardMembershipGateLib: addr.beamioUserCardMembershipGateLib,
    },
  };
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
    maxBuffer: 128 * 1024 * 1024,
  });
  const out = JSON.parse(res.stdout);
  const errs = (out.errors ?? []).filter((e) => e.severity === "error");
  if (errs.length) throw new Error(errs.map((e) => e.formattedMessage ?? e.message).join("\n"));
  return out.contracts[sourceKey][contractName].evm.deployedBytecode.object.toLowerCase();
}

const fullPath = path.join(root, FULL_REL);
if (!fs.existsSync(fullPath)) {
  throw new Error(`Missing ${FULL_REL} — run exportStandardJsonFromBuildInfo.mjs BeamioUserCard --full first`);
}

const input = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
delete input.settings?.compilationTarget;
const deps = getRecursiveDependencies(SOURCE_KEY, input.sources);
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
input.settings.libraries = loadLibLinks();

const outPath = path.join(root, outRel);
fs.writeFileSync(outPath, JSON.stringify(input), "utf-8");
const kb = (fs.statSync(outPath).size / 1024).toFixed(1);
console.log(`wrote ${outRel} (${kb} KB, ${Object.keys(input.sources).length} sources)`);

const local = compileDeployed(input, SOURCE_KEY, CONTRACT_NAME);
const chain = chainCode(CARD);
if (local !== chain) {
  console.error(`bytecode mismatch local=${local.length} chain=${chain.length}`);
  process.exit(1);
}
console.log(`✅ deployedBytecode match @ ${CARD}`);
console.log(`Next: CONET_VERIFY_BUILDINFO_JSON=${outRel} CONET_SOLC_VERSION=0.8.35+commit.47b9dedd ... verifyConetUserCardAtAddressOnScan.ts`);
