/**
 * Verify DeveloperFxIssuer (+ linked TreasuryDeveloperFxLib) on CoNET Blockscout.
 *
 * Usage:
 *   ISSUER=0x… FX_LIB=0x… npx tsx scripts/verifyDeveloperFxIssuerConet.ts
 *   (or read from deployments/conet-developer-fx-stake-gate.json / conet-addresses.json)
 */
import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";
import { FormData, File } from "undici";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BASE_URL = "https://mainnet.conet.network";
const COMPILER_VERSION = "v0.8.33+commit.64118f21";
const ROOT = "project/src/b-unit/DeveloperFxIssuer.sol";
const NAME = "DeveloperFxIssuer";
const LIB_ROOT = "project/src/b-unit/TreasuryDeveloperFxLib.sol";
const LIB_NAME = "TreasuryDeveloperFxLib";

function loadAddrs(): { issuer: string; lib: string; owner?: string } {
  const gatePath = path.join(__dirname, "../deployments/conet-developer-fx-stake-gate.json");
  const addrPath = path.join(__dirname, "../deployments/conet-addresses.json");
  const gate = fs.existsSync(gatePath) ? JSON.parse(fs.readFileSync(gatePath, "utf-8")) : {};
  const addresses = fs.existsSync(addrPath) ? JSON.parse(fs.readFileSync(addrPath, "utf-8")) : {};
  const issuer = (process.env.ISSUER || gate.developerFxIssuer || addresses.DeveloperFxIssuer || "").trim();
  const lib = (process.env.FX_LIB || gate.treasuryDeveloperFxLib || addresses.TreasuryDeveloperFxLib || "").trim();
  if (!issuer) throw new Error("ISSUER / DeveloperFxIssuer missing");
  if (!lib) throw new Error("FX_LIB / TreasuryDeveloperFxLib missing");
  return { issuer, lib };
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

function prune(
  full: { language: string; sources: Record<string, { content: string }>; settings: Record<string, unknown> },
  rootKey: string,
  libraries?: Record<string, Record<string, string>>,
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
  const settings = { ...full.settings, remappings: [] as string[] };
  delete (settings as { compilationTarget?: unknown }).compilationTarget;
  if (libraries) settings.libraries = libraries;
  settings.outputSelection = {
    "*": { "": ["ast"], "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"] },
  };
  const normalized: Record<string, { content: string }> = {};
  for (const [key, val] of Object.entries(prunedSources)) {
    let nk = key;
    const mm = key.match(/^npm\/(@openzeppelin\/[^@]+)@[^/]+\/(.+)$/);
    if (mm) nk = `${mm[1]}/${mm[2]}`;
    normalized[nk] = val;
  }
  return { language: full.language, sources: normalized, settings };
}

async function checkVerified(addr: string): Promise<boolean> {
  const r = await fetch(`${BASE_URL}/api/v2/smart-contracts/${addr}`);
  if (!r.ok) return false;
  const d = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean; source_code?: string };
  return Boolean(d.is_verified || d.is_partially_verified || (d.source_code && d.source_code.length > 0));
}

async function verifyOne(opts: {
  address: string;
  rootKey: string;
  artifactName: string;
  contractName: string;
  constructorArgsHex: string | null;
  libraries?: Record<string, Record<string, string>>;
}) {
  console.log(`\nVerify ${opts.artifactName}`, opts.address);
  if (await checkVerified(opts.address)) {
    console.log("✅ Already verified");
    return;
  }
  const art = JSON.parse(
    fs.readFileSync(
      path.join(__dirname, `../artifacts/src/b-unit/${opts.artifactName}.sol/${opts.artifactName}.json`),
      "utf-8",
    ),
  ) as { buildInfoId: string };
  const buildInfo = JSON.parse(
    fs.readFileSync(path.join(__dirname, `../artifacts/build-info/${art.buildInfoId}.json`), "utf-8"),
  );
  const pruned = prune(buildInfo.input, opts.rootKey, opts.libraries);
  const json = JSON.stringify(pruned);
  const out = path.join(__dirname, `../deployments/conet-${opts.artifactName}-verify-buildinfo.json`);
  fs.writeFileSync(out, json + "\n");
  console.log(`pruned ${Object.keys(pruned.sources).length} sources, ${(json.length / 1024).toFixed(1)} KB → ${out}`);

  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", opts.contractName);
  form.set("license_type", "mit");
  if (opts.constructorArgsHex) {
    form.set("constructor_args", opts.constructorArgsHex);
    form.set("autodetect_constructor_args", "false");
  } else {
    form.set("autodetect_constructor_args", "true");
  }
  form.set("files[0]", new File([json], "standard-input.json", { type: "application/json" }));
  const res = await fetch(`${BASE_URL}/api/v2/smart-contracts/${opts.address}/verification/via/standard-input`, {
    method: "POST",
    body: form as unknown as BodyInit,
  });
  console.log("submit", res.status, (await res.text()).slice(0, 300));
  for (let i = 0; i < 90; i++) {
    if (await checkVerified(opts.address)) {
      console.log("✅ Verified:", `${BASE_URL}/address/${opts.address}#code`);
      return;
    }
    await new Promise((r) => setTimeout(r, 4000));
    process.stdout.write(".");
  }
  throw new Error(`poll timeout: ${opts.address}`);
}

async function main() {
  const { issuer, lib } = loadAddrs();

  // 1) Library (no ctor)
  await verifyOne({
    address: lib,
    rootKey: LIB_ROOT,
    artifactName: LIB_NAME,
    contractName: `${LIB_ROOT}:${LIB_NAME}`,
    constructorArgsHex: null,
  });

  // 2) Issuer — constructor(owner). Owner = deployer admin; autodetect usually works.
  // Prefer explicit: read owner() if RPC available via env OWNER, else autodetect.
  let ctorHex: string | null = null;
  const owner = (process.env.OWNER || "").trim();
  if (owner) {
    ctorHex = AbiCoder.defaultAbiCoder().encode(["address"], [owner]).slice(2);
  }

  await verifyOne({
    address: issuer,
    rootKey: ROOT,
    artifactName: NAME,
    contractName: `${ROOT}:${NAME}`,
    constructorArgsHex: ctorHex,
    libraries: {
      [LIB_ROOT]: { [LIB_NAME]: lib },
    },
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
