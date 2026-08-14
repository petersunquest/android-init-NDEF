/**
 * Export + prune + Blockscout v2 verify TreasuryBridgeV3 implementation.
 * Usage: npx tsx scripts/verifyTreasuryBridgeV3ImplConet.ts
 */
import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { FormData, File } from "undici";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCAN = "https://mainnet.conet.network";
const RPC = process.env.CONET_RPC_URL || "https://rpc1.conet.network";
const COMPILER = "v0.8.33+commit.64118f21";
const SOURCE_KEY = "project/src/b-unit/TreasuryBridgeV3.sol";
const CONTRACT_NAME = "project/src/b-unit/TreasuryBridgeV3.sol:TreasuryBridgeV3";

const addresses = JSON.parse(
  fs.readFileSync(path.join(__dirname, "..", "deployments", "conet-addresses.json"), "utf-8")
) as { TreasuryBridgeV3Impl?: string };
const ADDR = (process.env.TREASURY_IMPL || addresses.TreasuryBridgeV3Impl || "").trim();
if (!ADDR) throw new Error("missing TreasuryBridgeV3Impl");

/** Apply Hardhat context remappings: prefix=target */
function applyRemappings(spec: string, remappings: string[]): string {
  let best: { from: string; to: string } | null = null;
  for (const raw of remappings) {
    const eq = raw.indexOf("=");
    if (eq < 0) continue;
    const from = raw.slice(0, eq);
    const to = raw.slice(eq + 1);
    // strip optional context prefix "project/:" or "npm/.../:"
    const colon = from.lastIndexOf(":");
    const prefix = colon >= 0 ? from.slice(colon + 1) : from;
    if (spec.startsWith(prefix) && (!best || prefix.length > best.from.length)) {
      best = { from: prefix, to };
    }
  }
  if (!best) return spec;
  return best.to + spec.slice(best.from.length);
}

function resolveImport(
  fromKey: string,
  spec: string,
  sources: Record<string, unknown>,
  remappings: string[]
): string | null {
  const candidates = new Set<string>([spec, applyRemappings(spec, remappings)]);
  if (spec.startsWith("./") || spec.startsWith("../")) {
    const fromDir = path.posix.dirname(fromKey.replace(/^project\//, ""));
    const joined = path.posix.normalize(path.posix.join(fromDir, spec));
    candidates.add(`project/${joined}`);
    candidates.add(joined);
  }
  for (const c of candidates) {
    if (sources[c]) return c;
  }
  return null;
}

/** npm/@oz@ver/X → @openzeppelin/.../X for Blockscout UI */
function normalizeNpmSourceKeys(input: {
  language: string;
  sources: Record<string, { content: string }>;
  settings: any;
}) {
  const sources = input.sources;
  const remapped: Record<string, { content: string }> = {};
  for (const [key, val] of Object.entries(sources)) {
    let next = key;
    const mUp = key.match(/^npm\/@openzeppelin\/contracts-upgradeable@[^/]+\/(.+)$/);
    const mBase = key.match(/^npm\/@openzeppelin\/contracts@[^/]+\/(.+)$/);
    if (mUp) next = `@openzeppelin/contracts-upgradeable/${mUp[1]}`;
    else if (mBase) next = `@openzeppelin/contracts/${mBase[1]}`;
    remapped[next] = val;
  }
  const settings = { ...input.settings };
  delete settings.compilationTarget;
  settings.remappings = [];
  settings.outputSelection = {
    "*": {
      "": ["ast"],
      "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
    },
  };
  return { language: input.language, sources: remapped, settings };
}

function prune(full: any, rootKey: string) {
  const sources = full.sources as Record<string, { content: string }>;
  const remappings: string[] = Array.isArray(full.settings?.remappings) ? full.settings.remappings : [];
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
      const resolved = resolveImport(cur, m[1], sources, remappings);
      if (resolved && !keep.has(resolved)) stack.push(resolved);
    }
  }
  const prunedSources: Record<string, { content: string }> = {};
  for (const k of keep) prunedSources[k] = sources[k];
  return normalizeNpmSourceKeys({
    language: full.language,
    sources: prunedSources,
    settings: { ...full.settings },
  });
}

async function isVerified(addr: string): Promise<boolean> {
  const r = await fetch(`${SCAN}/api/v2/smart-contracts/${addr}`);
  if (!r.ok) return false;
  const d = (await r.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string;
  };
  return Boolean(d.is_verified || d.is_partially_verified || (d.source_code && d.source_code.length > 20));
}

async function localBytecodeMatch(prunedPath: string, addr: string): Promise<boolean> {
  const solcCandidates = [
    path.join(
      process.env.HOME || "",
      "Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.33+commit.64118f21"
    ),
    path.join(
      process.env.HOME || "",
      ".cache/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.33+commit.64118f21"
    ),
  ];
  const solc = solcCandidates.find((p) => fs.existsSync(p));
  if (!solc) {
    console.log("skip local bytecode precheck (solc 0.8.33 not in hardhat cache)");
    return true;
  }
  const outPath = "/tmp/treasury-bridge-v3-verify-out.json";
  execSync(`"${solc}" --standard-json "${prunedPath}" > "${outPath}"`, { shell: true });
  const out = JSON.parse(fs.readFileSync(outPath, "utf-8"));
  const obj =
    out?.contracts?.[SOURCE_KEY]?.TreasuryBridgeV3?.evm?.deployedBytecode?.object ||
    out?.contracts?.["src/b-unit/TreasuryBridgeV3.sol"]?.TreasuryBridgeV3?.evm?.deployedBytecode
      ?.object;
  if (!obj) {
    console.log("local compile missing deployedBytecode; errors:", JSON.stringify(out.errors || []).slice(0, 500));
    return false;
  }
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
  const onchain = (j.result || "0x").replace(/^0x/i, "").toLowerCase();
  const local = String(obj).replace(/^0x/i, "").toLowerCase();
  if (onchain === local) {
    console.log(`local bytecode match: exact (len=${local.length})`);
    return true;
  }
  if (onchain.length !== local.length) {
    console.log(`local bytecode length mismatch local=${local.length} onchain=${onchain.length}`);
    return false;
  }
  // UUPS/OZ often embed address(this) immutables; local zeros vs on-chain address.
  let immutableNibbles = 0;
  let otherDiffs = 0;
  const addrNo0x = addr.replace(/^0x/i, "").toLowerCase();
  for (let i = 0; i < local.length; i++) {
    if (local[i] === onchain[i]) continue;
    // treat 20-byte zero runs that match address on-chain as immutable slots
    if (local.slice(i, i + 40) === "0".repeat(40) && onchain.slice(i, i + 40) === addrNo0x) {
      immutableNibbles += 40;
      i += 39;
      continue;
    }
    otherDiffs++;
  }
  console.log(
    `local bytecode: immutable-slot diffs≈${immutableNibbles / 2}B otherNibbleDiffs=${otherDiffs}`
  );
  return otherDiffs === 0;
}

async function main() {
  console.log("Verify TreasuryBridgeV3 impl", ADDR);
  if (await isVerified(ADDR)) {
    console.log("✅ already verified");
    return;
  }

  console.log("[1] export FULL standard JSON");
  execSync("node scripts/exportStandardJsonFromBuildInfo.mjs TreasuryBridgeV3 --full", {
    cwd: path.join(__dirname, ".."),
    stdio: "inherit",
  });

  const fullPath = path.join(__dirname, "..", "deployments", "base-TreasuryBridgeV3-standard-input-FULL.json");
  const full = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
  const pruned = prune(full, SOURCE_KEY);
  const prunedPath = path.join(__dirname, "..", "deployments", "conet-TreasuryBridgeV3-verify-buildinfo.json");
  fs.writeFileSync(prunedPath, JSON.stringify(pruned) + "\n");
  console.log(`[2] pruned sources=${Object.keys(pruned.sources).length} → ${prunedPath}`);

  if (!(await localBytecodeMatch(prunedPath, ADDR))) {
    throw new Error("local deployedBytecode != eth_getCode; abort Blockscout submit");
  }

  const form = new FormData();
  form.set("compiler_version", COMPILER);
  form.set("contract_name", CONTRACT_NAME);
  form.set("autodetect_constructor_args", "true");
  form.set("license_type", "mit");
  form.set(
    "files[0]",
    new File([JSON.stringify(pruned)], "TreasuryBridgeV3.json", { type: "application/json" })
  );

  const url = `${SCAN}/api/v2/smart-contracts/${ADDR}/verification/via/standard-input`;
  console.log("[3] submit Blockscout v2 standard-input");
  const res = await fetch(url, { method: "POST", body: form as any });
  const text = await res.text();
  console.log(`HTTP ${res.status}: ${text.slice(0, 400)}`);

  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 4000));
    if (await isVerified(ADDR)) {
      console.log(`✅ verified: ${ADDR}`);
      return;
    }
    process.stdout.write(".");
  }
  console.log("\n⚠️ poll timeout — check Blockscout manually");
  process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
