/**
 * Blockscout Standard JSON 验证 ValidatorDepositRedeem implementation
 * （native-lock-fix，0x8Cc833854AA38009716F69c23706e3fb63F21A95）
 *
 * 运行（在 BeamioContract 根目录）:
 *   npx tsx scripts/verifyValidatorDepositRedeemImplNativeLockConet.ts
 *
 * 可选:
 *   ADDRESS=0x… 覆盖 deployments/conet-ValidatorDepositRedeem-native-lock-fix.json
 *   SKIP_BYTECODE_CHECK=1 跳过本地 solc 字节码预检
 */

import * as fs from "fs";
import * as path from "path";
import { spawnSync } from "child_process";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";
import { FormData, File } from "undici";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.join(__dirname, "..");

const BASE_URL = "https://mainnet.conet.network";
const RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const COMPILER_VERSION = "v0.8.33+commit.64118f21";
const ROOT_KEY = "project/src/mainnet/ValidatorDepositRedeem.sol";
const CONTRACT_NAME = `${ROOT_KEY}:ValidatorDepositRedeem`;
const SOLC =
  process.env.SOLC ||
  `${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.33+commit.64118f21`;

type DeployInfo = {
  implementation: string;
  libraries: Record<string, string>;
};

function getDeployInfo(): DeployInfo {
  const p = path.join(ROOT, "deployments/conet-ValidatorDepositRedeem-native-lock-fix.json");
  const j = JSON.parse(fs.readFileSync(p, "utf-8")) as DeployInfo & { implementation?: string };
  const implementation = (process.env.ADDRESS || j.implementation || "").trim();
  if (!implementation) throw new Error("missing implementation address");
  if (!j.libraries || Object.keys(j.libraries).length === 0) {
    throw new Error("missing libraries in deployment json");
  }
  return { implementation, libraries: j.libraries };
}

function resolveBuildInfoPath(): string {
  const buildInfoDir = path.join(ROOT, "artifacts/build-info");
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
    throw new Error("No build-info with ValidatorDepositRedeem — run: npm run compile");
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

function buildLibrariesSettings(libs: Record<string, string>): Record<string, Record<string, string>> {
  const out: Record<string, Record<string, string>> = {};
  for (const [name, addr] of Object.entries(libs)) {
    const sourceKey = `project/src/mainnet/${name}.sol`;
    out[sourceKey] = { [name]: addr };
  }
  return out;
}

function pruneStandardJson(
  full: {
    language: string;
    sources: Record<string, { content: string }>;
    settings: Record<string, unknown>;
  },
  libraries: Record<string, Record<string, string>>,
) {
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
  settings.libraries = libraries;
  return normalizeNpmSourceKeys({
    language: full.language,
    sources: prunedSources,
    settings,
  });
}

async function ethGetCode(addr: string): Promise<string> {
  const r = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_getCode",
      params: [addr, "latest"],
    }),
  });
  const j = (await r.json()) as { result?: string };
  return (j.result || "0x").toLowerCase();
}

function localDeployedBytecode(prunedPath: string): string {
  if (!fs.existsSync(SOLC)) {
    console.warn(`[precheck] solc missing at ${SOLC}; skip local bytecode match`);
    return "";
  }
  const res = spawnSync(SOLC, ["--standard-json", prunedPath], {
    encoding: "utf-8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (res.status !== 0) {
    throw new Error(`solc failed: ${res.stderr || res.stdout}`);
  }
  const out = JSON.parse(res.stdout);
  const obj = out?.contracts?.[ROOT_KEY]?.ValidatorDepositRedeem?.evm?.deployedBytecode?.object;
  if (!obj) {
    const errs = JSON.stringify(out?.errors?.slice?.(0, 5) || out?.errors || "no bytecode", null, 2);
    throw new Error(`no deployedBytecode for ${CONTRACT_NAME}\n${errs}`);
  }
  return `0x${obj}`.toLowerCase();
}

async function checkVerified(addr: string): Promise<boolean> {
  const r = await fetch(`${BASE_URL}/api/v2/smart-contracts/${addr}`);
  if (!r.ok) return false;
  const d = (await r.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string;
  };
  return Boolean(d.is_verified || d.is_partially_verified || (d.source_code && d.source_code.length > 20));
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
  const { implementation, libraries } = getDeployInfo();
  const statsLib = libraries.ValidatorDepositRedeemStatsLib;
  if (!statsLib) throw new Error("missing ValidatorDepositRedeemStatsLib in deployment libraries");

  console.log("=".repeat(60));
  console.log("Verify ValidatorDepositRedeem impl (native-lock-fix)");
  console.log("=".repeat(60));
  console.log("address:", implementation);
  console.log("constructor unifiedStatsLib_:", statsLib);
  console.log("linked libraries:", Object.keys(libraries).length);

  if (await checkVerified(implementation)) {
    console.log("✅ Already verified:", `${BASE_URL}/address/${implementation}#code`);
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

  const libSettings = buildLibrariesSettings(libraries);
  const pruned = pruneStandardJson(fullInput, libSettings);
  const outPath = path.join(ROOT, "deployments/conet-ValidatorDepositRedeem-native-lock-impl-verify-buildinfo.json");
  fs.writeFileSync(outPath, JSON.stringify(pruned) + "\n");
  const json = JSON.stringify(pruned);
  console.log(`pruned sources: ${Object.keys(pruned.sources).length}`);
  console.log(`Standard JSON size: ${(json.length / 1024).toFixed(1)} KB`);
  console.log(`viaIR: ${(pruned.settings as { viaIR?: boolean }).viaIR}`);
  console.log(`wrote ${outPath}`);

  if (process.env.SKIP_BYTECODE_CHECK !== "1") {
    let local = localDeployedBytecode(outPath);
    const onchain = await ethGetCode(implementation);
    if (local) {
      // Patch solc zero placeholders for address(this) + constructor immutables (StatsLib).
      const patchAddrs = [
        implementation.replace(/^0x/, "").toLowerCase().padStart(40, "0"),
        statsLib.replace(/^0x/, "").toLowerCase().padStart(40, "0"),
      ];
      let patched = local.startsWith("0x") ? local.slice(2) : local;
      const chainBody = onchain.startsWith("0x") ? onchain.slice(2) : onchain;
      if (patched.length === chainBody.length) {
        for (let i = 0; i + 40 <= patched.length; i += 2) {
          const slot = patched.slice(i, i + 40);
          const chainSlot = chainBody.slice(i, i + 40);
          if (slot === "0".repeat(40) && patchAddrs.includes(chainSlot)) {
            patched = patched.slice(0, i) + chainSlot + patched.slice(i + 40);
          }
        }
        local = `0x${patched}`;
      }
      if (local !== onchain) {
        console.error(`bytecode mismatch localLen=${local.length} chainLen=${onchain.length}`);
        console.error(`localTail=${local.slice(-40)} chainTail=${onchain.slice(-40)}`);
        let diffBytes = 0;
        const L = local.slice(2);
        const C = chainBody;
        for (let i = 0; i < L.length; i += 2) {
          if (L.slice(i, i + 2) !== C.slice(i, i + 2)) diffBytes++;
        }
        console.error(`remaining diff bytes=${diffBytes}`);
        throw new Error("local solc deployedBytecode != eth_getCode — abort submit");
      }
      console.log("local bytecode matches chain ✅");
    }
  }

  const encoded = AbiCoder.defaultAbiCoder().encode(["address"], [statsLib]);
  const constructorArgsHex = encoded.startsWith("0x") ? encoded.slice(2) : encoded;

  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", CONTRACT_NAME);
  form.set("constructor_args", constructorArgsHex);
  form.set("autodetect_constructor_args", "false");
  form.set("license_type", "mit");
  form.set("files[0]", new File([json], "standard-input.json", { type: "application/json" }));

  const v2Url = `${BASE_URL}/api/v2/smart-contracts/${implementation}/verification/via/standard-input`;
  const res = await fetch(v2Url, { method: "POST", body: form as unknown as BodyInit });
  const text = await res.text();
  console.log(`submit → HTTP ${res.status}: ${text.slice(0, 500)}`);

  if (!res.ok && !/already verified/i.test(text)) {
    process.exit(1);
  }

  console.log("\nPolling verification status…");
  const verified = await pollVerified(implementation);
  console.log("");
  if (verified) {
    console.log("✅ Verified:", `${BASE_URL}/address/${implementation}#code`);
  } else {
    console.log("⏳ Submitted but not confirmed within timeout — check explorer manually.");
    console.log(`   ${BASE_URL}/address/${implementation}?tab=contract`);
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
