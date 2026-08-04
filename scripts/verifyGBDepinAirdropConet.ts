/**
 * Blockscout Standard JSON 验证 GBDepinAirdrop（CoNET 224422，via-IR）
 * 递归剪枝 build-info，避免 FULL 触发 Blockscout 413。
 *
 * 运行: npx tsx scripts/verifyGBDepinAirdropConet.ts
 * 可选: ADDRESS=0x… 覆盖 deployments/conet-GBDepinAirdrop.json
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";
import { FormData, File } from "undici";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_URL = "https://mainnet.conet.network";
const COMPILER_VERSION = "v0.8.33+commit.64118f21";
const ROOT_KEY = "project/src/b-unit/GBDepinAirdrop.sol";
const CONTRACT_NAME = `${ROOT_KEY}:GBDepinAirdrop`;

function getDeployInfo(): { address: string; gbToken: string; deployer: string } {
  if (process.env.ADDRESS) {
    const p = path.join(__dirname, "../deployments/conet-GBDepinAirdrop.json");
    const j = JSON.parse(fs.readFileSync(p, "utf-8")) as {
      deployer?: string;
      contracts?: { GBToken?: { address?: string } };
    };
    return {
      address: process.env.ADDRESS,
      gbToken: j.contracts?.GBToken?.address ?? "0xC3EF02DaE632b4C10abB66e07d92a387c10838D8",
      deployer: j.deployer ?? "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1",
    };
  }
  const p = path.join(__dirname, "../deployments/conet-GBDepinAirdrop.json");
  if (!fs.existsSync(p)) {
    throw new Error("Missing deployments/conet-GBDepinAirdrop.json — run deployGBDepinAirdropToConet.ts first");
  }
  const j = JSON.parse(fs.readFileSync(p, "utf-8")) as {
    deployer?: string;
    contracts?: {
      GBToken?: { address?: string };
      GBDepinAirdrop?: { address?: string };
    };
  };
  const address = j.contracts?.GBDepinAirdrop?.address;
  const gbToken = j.contracts?.GBToken?.address;
  const deployer = j.deployer;
  if (!address || !gbToken || !deployer) {
    throw new Error("deployment file missing GBDepinAirdrop / GBToken / deployer");
  }
  return { address, gbToken, deployer };
}

function resolveBuildInfoPath(): string {
  const buildInfoDir = path.join(__dirname, "../artifacts/build-info");
  const files = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  let best: { path: string; count: number } | null = null;
  for (const f of files) {
    const p = path.join(buildInfoDir, f);
    const content = fs.readFileSync(p, "utf-8");
    if (!content.includes(ROOT_KEY)) continue;
    const count = (content.match(/"project\//g) ?? []).length;
    if (!best || count > best.count) best = { path: p, count };
  }
  if (!best) {
    throw new Error("No build-info with GBDepinAirdrop — run: npm run clean && npm run compile");
  }
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

function pruneStandardJson(full: {
  language: string;
  sources: Record<string, { content: string }>;
  settings: Record<string, unknown>;
}) {
  const sources = full.sources;
  const keep = new Set<string>();
  const stack = [ROOT_KEY];
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
  const pruned = {
    language: full.language,
    sources: prunedSources,
    settings,
  };
  return normalizeNpmSourceKeys(pruned);
}

async function checkVerified(addr: string): Promise<boolean> {
  const r = await fetch(`${BASE_URL}/api/v2/smart-contracts/${addr}`);
  if (!r.ok) return false;
  const d = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean };
  return Boolean(d.is_verified || d.is_partially_verified);
}

async function pollVerified(addr: string, maxSec = 180): Promise<boolean> {
  for (let i = 0; i < maxSec; i += 4) {
    if (await checkVerified(addr)) return true;
    await new Promise((r) => setTimeout(r, 4000));
    process.stdout.write(".");
  }
  return checkVerified(addr);
}

async function main() {
  const { address, gbToken, deployer } = getDeployInfo();
  console.log("=".repeat(60));
  console.log("Verify GBDepinAirdrop (Blockscout Standard JSON, pruned)");
  console.log("=".repeat(60));
  console.log("address:", address);
  console.log("constructor: (gbToken, initialOwner) =", gbToken, deployer);

  if (await checkVerified(address)) {
    console.log("✅ Already verified:", `${BASE_URL}/address/${address}#code`);
    return;
  }

  const buildInfoPath = resolveBuildInfoPath();
  console.log("build-info:", path.basename(buildInfoPath));
  const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
  const fullInput = buildInfo.input as {
    language: string;
    sources: Record<string, { content: string }>;
    settings: Record<string, unknown>;
  };

  const pruned = pruneStandardJson(fullInput);
  const outPath = path.join(__dirname, "../deployments/conet-GBDepinAirdrop-verify-buildinfo.json");
  fs.writeFileSync(outPath, JSON.stringify(pruned) + "\n");
  const json = JSON.stringify(pruned);
  console.log(`pruned sources: ${Object.keys(pruned.sources).length}`);
  console.log(`Standard JSON size: ${(json.length / 1024).toFixed(1)} KB`);
  console.log(`viaIR: ${(pruned.settings as { viaIR?: boolean }).viaIR}`);

  const encoded = AbiCoder.defaultAbiCoder().encode(["address", "address"], [gbToken, deployer]);
  const constructorArgsHex = encoded.startsWith("0x") ? encoded.slice(2) : encoded;

  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", CONTRACT_NAME);
  form.set("constructor_args", constructorArgsHex);
  form.set("autodetect_constructor_args", "false");
  form.set("license_type", "mit");
  form.set("files[0]", new File([json], "standard-input.json", { type: "application/json" }));

  const v2Url = `${BASE_URL}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
  const res = await fetch(v2Url, { method: "POST", body: form as unknown as BodyInit });
  const text = await res.text();
  console.log(`submit → HTTP ${res.status}: ${text.slice(0, 400)}`);

  if (!res.ok && !/already verified/i.test(text)) {
    process.exit(1);
  }

  console.log("\nPolling verification status…");
  const verified = await pollVerified(address);
  console.log("");
  if (verified) {
    console.log("✅ Verified:", `${BASE_URL}/address/${address}#code`);
  } else {
    console.log("⏳ Submitted but not confirmed within timeout — check explorer manually.");
    console.log(`   ${BASE_URL}/address/${address}#code`);
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
