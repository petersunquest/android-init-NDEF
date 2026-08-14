/**
 * Blockscout verify DepinGbSettlement1155 implementation + ERC1967 proxy (CoNET 224422).
 *
 * Both were compiled with Hardhat 0.8.33 via-IR (not OZ prebuilt 0.8.27 proxy).
 *
 * Run: npx tsx scripts/verifyDepinGbSettlement1155Conet.ts
 * Env: IMPL= / PROXY= override addresses from deployments/conet-DepinGbSettlement1155.json
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
  const p = path.join(__dirname, "../deployments/conet-DepinGbSettlement1155.json");
  if (!fs.existsSync(p)) throw new Error("Missing deployments/conet-DepinGbSettlement1155.json");
  return JSON.parse(fs.readFileSync(p, "utf-8")) as {
    implementation: string;
    proxy: string;
    initializeArgs: {
      initialAdmin: string;
      gbToken: string;
      validatorDepositRedeem: string;
      uri: string;
      minBondWei: string;
      unbondDelay: string;
    };
  };
}

function resolveBuildInfoPath(rootKey: string, artifactName: string): string {
  const buildInfoDir = path.join(__dirname, "../artifacts/build-info");
  // Prefer the exact Hardhat artifact buildInfoId — "most sources" often picks a wrong unit.
  const artPath = path.join(__dirname, `../artifacts/src/b-unit/${artifactName}.sol/${artifactName}.json`);
  if (fs.existsSync(artPath)) {
    const art = JSON.parse(fs.readFileSync(artPath, "utf-8")) as { buildInfoId?: string };
    if (art.buildInfoId) {
      const exact = path.join(buildInfoDir, `${art.buildInfoId}.json`);
      if (fs.existsSync(exact)) return exact;
    }
  }
  const files = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  let best: { path: string; count: number } | null = null;
  for (const f of files) {
    const p = path.join(buildInfoDir, f);
    const content = fs.readFileSync(p, "utf-8");
    if (!content.includes(rootKey)) continue;
    const count = (content.match(/"project\//g) ?? []).length;
    if (!best || count > best.count) best = { path: p, count };
  }
  if (!best) throw new Error(`No build-info with ${rootKey} — run npm run compile`);
  return best.path;
}

function resolveImport(fromKey: string, spec: string, sources: Record<string, unknown>): string | null {
  if (sources[spec]) return spec;
  if (spec.startsWith("@")) {
    const rest = spec.split("/").slice(2).join("/");
    for (const k of Object.keys(sources)) {
      if (k.endsWith(`/${rest}`) || k.endsWith(rest)) return k;
    }
  }
  if (spec.startsWith("project/") && sources[spec]) return spec;
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
  const d = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean };
  return Boolean(d.is_verified || d.is_partially_verified);
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
  console.log("=".repeat(60));
  console.log("address:", t.address);
  console.log("contract:", t.contractName);

  if (await checkVerified(t.address)) {
    console.log("✅ Already verified:", `${BASE_URL}/address/${t.address}#code`);
    return;
  }

  const buildInfoPath = resolveBuildInfoPath(t.rootKey, t.artifactName);
  console.log("build-info:", path.basename(buildInfoPath));
  const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
  const fullInput = buildInfo.input as {
    language: string;
    sources: Record<string, { content: string }>;
    settings: Record<string, unknown>;
  };
  const pruned = pruneStandardJson(fullInput, t.rootKey);
  const outPath = path.join(
    __dirname,
    `../deployments/conet-${t.label.replace(/\s+/g, "")}-verify-buildinfo.json`,
  );
  fs.writeFileSync(outPath, JSON.stringify(pruned) + "\n");
  const json = JSON.stringify(pruned);
  console.log(`pruned sources: ${Object.keys(pruned.sources).length}`);
  console.log(`Standard JSON size: ${(json.length / 1024).toFixed(1)} KB`);

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

  const v2Url = `${BASE_URL}/api/v2/smart-contracts/${t.address}/verification/via/standard-input`;
  const res = await fetch(v2Url, { method: "POST", body: form as unknown as BodyInit });
  const text = await res.text();
  console.log(`submit → HTTP ${res.status}: ${text.slice(0, 400)}`);
  if (!res.ok && !/already verified/i.test(text)) {
    throw new Error(`verify submit failed for ${t.label}`);
  }

  console.log("Polling…");
  const ok = await pollVerified(t.address);
  console.log("");
  if (!ok) throw new Error(`verify poll timeout for ${t.label}: ${BASE_URL}/address/${t.address}#code`);
  console.log("✅ Verified:", `${BASE_URL}/address/${t.address}#code`);
}

async function main() {
  const d = loadDeploy();
  const impl = process.env.IMPL || d.implementation;
  const proxy = process.env.PROXY || d.proxy;
  const a = d.initializeArgs;

  const initData = new Interface([
    "function initialize(address,address,address,string,uint256,uint256)",
  ]).encodeFunctionData("initialize", [
    a.initialAdmin,
    a.gbToken,
    a.validatorDepositRedeem,
    a.uri,
    BigInt(a.minBondWei),
    BigInt(a.unbondDelay),
  ]);

  const proxyArgs = AbiCoder.defaultAbiCoder().encode(["address", "bytes"], [impl, initData]);
  const proxyArgsHex = proxyArgs.startsWith("0x") ? proxyArgs.slice(2) : proxyArgs;

  const targets: Target[] = [
    {
      label: "DepinGbSettlement1155Impl",
      address: impl,
      rootKey: "project/src/b-unit/DepinGbSettlement1155.sol",
      artifactName: "DepinGbSettlement1155",
      contractName: "project/src/b-unit/DepinGbSettlement1155.sol:DepinGbSettlement1155",
      constructorArgsHex: null,
    },
  ];
  if (process.env.SKIP_PROXY !== "1") {
    targets.push({
      label: "DepinGbSettlement1155Proxy",
      address: proxy,
      rootKey: "project/src/b-unit/DepinGbSettlement1155Proxy.sol",
      artifactName: "DepinGbSettlement1155Proxy",
      contractName: "project/src/b-unit/DepinGbSettlement1155Proxy.sol:DepinGbSettlement1155Proxy",
      constructorArgsHex: proxyArgsHex,
    });
  }

  for (const t of targets) {
    await verifyOne(t);
  }
  console.log("\nAll verification targets done.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
