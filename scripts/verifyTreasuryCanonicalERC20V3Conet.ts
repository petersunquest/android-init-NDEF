/**
 * Verify TreasuryCanonicalERC20V3 implementation on CoNET Blockscout.
 * Usage: IMPL=0x… npx tsx scripts/verifyTreasuryCanonicalERC20V3Conet.ts
 */
import { execSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { fileURLToPath } from "url";
import { FormData } from "undici";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BASE_URL = "https://mainnet.conet.network";
const COMPILER_VERSION = process.env.COMPILER_VERSION || "v0.8.35+commit.47b9dedd";
const ROOT = "project/src/b-unit/TreasuryCanonicalERC20V3.sol";
const NAME = "TreasuryCanonicalERC20V3";

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

function prune(full: { language: string; sources: Record<string, { content: string }>; settings: Record<string, unknown> }) {
  const sources = full.sources;
  const keep = new Set<string>();
  const stack = [ROOT];
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

async function main() {
  const addr =
    process.env.IMPL ||
    (JSON.parse(fs.readFileSync(path.join(__dirname, "../deployments/conet-TestDeveloperFxERC20.json"), "utf-8"))
      .tokenImpl as string);
  if (!addr) throw new Error("IMPL or deployments tokenImpl required");
  console.log("Verify TreasuryCanonicalERC20V3 impl", addr);
  if (await checkVerified(addr)) {
    console.log("✅ Already verified");
    return;
  }
  const art = JSON.parse(
    fs.readFileSync(path.join(__dirname, `../artifacts/src/b-unit/${NAME}.sol/${NAME}.json`), "utf-8"),
  ) as { buildInfoId: string };
  const buildInfo = JSON.parse(
    fs.readFileSync(path.join(__dirname, `../artifacts/build-info/${art.buildInfoId}.json`), "utf-8"),
  );
  const pruned = prune(buildInfo.input);
  const json = JSON.stringify(pruned);
  fs.writeFileSync(path.join(__dirname, "../deployments/conet-TreasuryCanonicalERC20V3Impl-verify-buildinfo.json"), json + "\n");
  console.log(`pruned ${Object.keys(pruned.sources).length} sources, ${(json.length / 1024).toFixed(1)} KB`);
  const prunedPath = path.join(__dirname, "../deployments/conet-TreasuryCanonicalERC20V3Impl-verify-buildinfo.json");
  const solc = path.join(
    os.homedir(),
    "Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.35+commit.47b9dedd",
  );
  if (!fs.existsSync(solc)) throw new Error("solc 0.8.35 missing");
  const outPath = "/tmp/wcnet-verify-out.json";
  execSync(`"${solc}" --standard-json "${prunedPath}" > "${outPath}"`, { shell: true });
  const compiled = JSON.parse(fs.readFileSync(outPath, "utf-8"));
  const local = String(
    compiled?.contracts?.[ROOT]?.[NAME]?.evm?.deployedBytecode?.object || "",
  ).replace(/^0x/i, "").toLowerCase();
  if (!local) throw new Error("local deployedBytecode missing");
  const rpc = await fetch(process.env.CONET_RPC_URL || "https://rpc1.conet.network", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [addr, "latest"] }),
  });
  const onchain = String(((await rpc.json()) as { result?: string }).result || "")
    .replace(/^0x/i, "")
    .toLowerCase();
  if (onchain !== local) {
    if (onchain.length !== local.length) {
      throw new Error(`bytecode mismatch local=${local.length} onchain=${onchain.length}`);
    }
    const addrNo0x = addr.replace(/^0x/i, "").toLowerCase();
    let other = 0;
    for (let i = 0; i < local.length; i++) {
      if (local[i] === onchain[i]) continue;
      if (local.slice(i, i + 40) === "0".repeat(40) && onchain.slice(i, i + 40) === addrNo0x) {
        i += 39;
        continue;
      }
      other++;
    }
    if (other !== 0) throw new Error(`bytecode mismatch otherNibbleDiffs=${other}`);
    console.log("local bytecode match except implementation immutables");
  } else {
    console.log(`local bytecode match len=${local.length / 2}`);
  }

  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", `${ROOT}:${NAME}`);
  form.set("license_type", "mit");
  form.set("autodetect_constructor_args", "true");
  form.set("files[0]", new File([json], "standard-input.json", { type: "application/json" }));
  const res = await fetch(`${BASE_URL}/api/v2/smart-contracts/${addr}/verification/via/standard-input`, {
    method: "POST",
    body: form as unknown as BodyInit,
  });
  console.log("submit", res.status, (await res.text()).slice(0, 200));
  for (let i = 0; i < 60; i++) {
    if (await checkVerified(addr)) {
      console.log("✅ Verified:", `${BASE_URL}/address/${addr}#code`);
      return;
    }
    await new Promise((r) => setTimeout(r, 4000));
    process.stdout.write(".");
  }
  throw new Error("poll timeout");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
