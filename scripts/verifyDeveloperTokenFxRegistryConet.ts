/**
 * Blockscout verify DeveloperTokenFxRegistry implementation + proxy (CoNET 224422).
 *
 * Run: node --import tsx scripts/verifyDeveloperTokenFxRegistryConet.ts
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder, Interface } from "ethers";
import { fileURLToPath } from "url";
import { FormData, File } from "undici";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_URL = "https://mainnet.conet.network";
const COMPILER_VERSION = "v0.8.33+commit.64118f21";

type Target = {
  label: string;
  address: string;
  rootKey: string;
  artifactName: string;
  contractName: string;
  constructorArgsHex: string | null;
};

function loadDeploy() {
  const p = path.join(__dirname, "../deployments/conet-DeveloperTokenFxRegistry.json");
  if (!fs.existsSync(p)) throw new Error("Missing deployments/conet-DeveloperTokenFxRegistry.json");
  return JSON.parse(fs.readFileSync(p, "utf-8")) as {
    implementation: string;
    proxy: string;
    initializeArgs: { initialAdmin: string; gbToken: string; settlement: string };
  };
}

function resolveBuildInfoPath(rootKey: string, artifactName: string): string {
  const buildInfoDir = path.join(__dirname, "../artifacts/build-info");
  const artPath = path.join(__dirname, `../artifacts/src/b-unit/${artifactName}.sol/${artifactName}.json`);
  if (fs.existsSync(artPath)) {
    const art = JSON.parse(fs.readFileSync(artPath, "utf-8")) as { buildInfoId?: string };
    if (art.buildInfoId) {
      const exact = path.join(buildInfoDir, `${art.buildInfoId}.json`);
      if (fs.existsSync(exact)) return exact;
    }
  }
  throw new Error(`No build-info for ${artifactName} — run npm run compile`);
}

function resolveImport(fromKey: string, spec: string, sources: Record<string, unknown>): string | null {
  if (sources[spec]) return spec;
  if (spec.startsWith("@")) {
    const rest = spec.split("/").slice(2).join("/");
    for (const k of Object.keys(sources)) {
      if (k.endsWith(`/${rest}`) || k.endsWith(rest)) return k;
    }
  }
  const fromDir = path.posix.dirname(fromKey.replace(/^project\//, ""));
  const joined = path.posix.normalize(path.posix.join(fromDir, spec));
  for (const c of [`project/${joined}`, joined]) {
    if (sources[c]) return c;
  }
  return null;
}

function normalizeNpmSourceKeys(input: {
  language: string;
  sources: Record<string, { content: string }>;
  settings: Record<string, unknown>;
}) {
  const normalized: Record<string, { content: string }> = {};
  for (const [key, val] of Object.entries(input.sources)) {
    let nk = key;
    const m = key.match(/^npm\/(@openzeppelin\/[^@]+)@[^/]+\/(.+)$/);
    if (m) nk = `${m[1]}/${m[2]}`;
    normalized[nk] = val;
  }
  const settings = { ...input.settings, remappings: [] };
  delete (settings as { compilationTarget?: unknown }).compilationTarget;
  return { language: input.language, sources: normalized, settings };
}

function pruneStandardJson(
  full: {
    language: string;
    sources: Record<string, { content: string }>;
    settings: Record<string, unknown>;
  },
  rootKey: string,
) {
  const sources = full.sources;
  const keep = new Set<string>();
  const stack = [rootKey];
  while (stack.length) {
    const cur = stack.pop()!;
    if (keep.has(cur) || !sources[cur]) continue;
    keep.add(cur);
    const content = sources[cur].content || "";
    const importRe = /import\s+(?:[^'"]*\s+from\s+)?["']([^"']+)["']/g;
    let m: RegExpExecArray | null;
    while ((m = importRe.exec(content))) {
      const resolved = resolveImport(cur, m[1], sources);
      if (resolved && !keep.has(resolved)) stack.push(resolved);
    }
  }
  const prunedSources: Record<string, { content: string }> = {};
  for (const k of keep) prunedSources[k] = sources[k];
  const settings = { ...full.settings };
  delete (settings as { compilationTarget?: unknown }).compilationTarget;
  settings.outputSelection = {
    "*": {
      "": ["ast"],
      "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
    },
  };
  settings.remappings = [];
  return normalizeNpmSourceKeys({ language: full.language, sources: prunedSources, settings });
}

async function checkVerified(addr: string): Promise<boolean> {
  const r = await fetch(`${BASE_URL}/api/v2/smart-contracts/${addr}`);
  if (!r.ok) return false;
  const d = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean; source_code?: string };
  return Boolean(d.is_verified || d.is_partially_verified || (d.source_code && d.source_code.length > 0));
}

async function pollVerified(addr: string, maxSec = 240): Promise<boolean> {
  for (let i = 0; i < maxSec; i += 4) {
    if (await checkVerified(addr)) return true;
    await new Promise((r) => setTimeout(r, 4000));
    process.stdout.write(".");
  }
  return checkVerified(addr);
}

async function verifyOne(t: Target): Promise<void> {
  console.log("\n" + "=".repeat(60));
  console.log(`Verify ${t.label}`);
  console.log("address:", t.address);
  if (await checkVerified(t.address)) {
    console.log("✅ Already verified");
    return;
  }
  const buildInfoPath = resolveBuildInfoPath(t.rootKey, t.artifactName);
  console.log("build-info:", path.basename(buildInfoPath));
  const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
  const pruned = pruneStandardJson(buildInfo.input, t.rootKey);
  const outPath = path.join(__dirname, `../deployments/conet-${t.label}-verify-buildinfo.json`);
  fs.writeFileSync(outPath, JSON.stringify(pruned) + "\n");
  const json = JSON.stringify(pruned);
  console.log(`pruned sources: ${Object.keys(pruned.sources).length}, ${(json.length / 1024).toFixed(1)} KB`);

  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", t.contractName);
  form.set("license_type", "mit");
  if (t.constructorArgsHex) {
    form.set("constructor_args", t.constructorArgsHex);
    form.set("autodetect_constructor_args", "false");
  } else {
    form.set("autodetect_constructor_args", "true");
  }
  form.set("files[0]", new File([json], "standard-input.json", { type: "application/json" }));

  const res = await fetch(`${BASE_URL}/api/v2/smart-contracts/${t.address}/verification/via/standard-input`, {
    method: "POST",
    body: form as unknown as BodyInit,
  });
  const text = await res.text();
  console.log(`submit → HTTP ${res.status}: ${text.slice(0, 300)}`);
  if (!res.ok && !/already verified/i.test(text)) throw new Error(`submit failed: ${t.label}`);
  console.log("Polling…");
  if (!(await pollVerified(t.address))) throw new Error(`poll timeout: ${t.address}`);
  console.log("\n✅ Verified:", `${BASE_URL}/address/${t.address}#code`);
}

async function main() {
  const d = loadDeploy();
  const impl = process.env.IMPL || d.implementation;
  const proxy = process.env.PROXY || d.proxy;
  const a = d.initializeArgs;
  const initData = new Interface([
    "function initialize(address,address,address)",
  ]).encodeFunctionData("initialize", [a.initialAdmin, a.gbToken, a.settlement]);
  const proxyArgsHex = AbiCoder.defaultAbiCoder()
    .encode(["address", "bytes"], [impl, initData])
    .slice(2);

  const targets: Target[] = [
    {
      label: "DeveloperTokenFxRegistryImpl",
      address: impl,
      rootKey: "project/src/b-unit/DeveloperTokenFxRegistry.sol",
      artifactName: "DeveloperTokenFxRegistry",
      contractName: "project/src/b-unit/DeveloperTokenFxRegistry.sol:DeveloperTokenFxRegistry",
      constructorArgsHex: null,
    },
  ];
  if (process.env.SKIP_PROXY !== "1") {
    targets.push({
      label: "DeveloperTokenFxRegistryProxy",
      address: proxy,
      rootKey: "project/src/b-unit/DeveloperTokenFxRegistryProxy.sol",
      artifactName: "DeveloperTokenFxRegistryProxy",
      contractName: "project/src/b-unit/DeveloperTokenFxRegistryProxy.sol:DeveloperTokenFxRegistryProxy",
      constructorArgsHex: proxyArgsHex,
    });
  }
  for (const t of targets) {
    await verifyOne(t);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
