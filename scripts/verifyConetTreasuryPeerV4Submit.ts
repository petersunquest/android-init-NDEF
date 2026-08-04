/**
 * 剪枝 Standard JSON 并提交 Blockscout v2 standard-input（Peer v4 栈）。
 * 用法: npx tsx scripts/verifyConetTreasuryPeerV4Submit.ts
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { FormData, File } from "undici";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCAN = "https://mainnet.conet.network";
const COMPILER = "v0.8.33+commit.64118f21";

const meta = JSON.parse(
  fs.readFileSync(path.join(__dirname, "..", "deployments", "conet-TreasuryPeer-v4.json"), "utf-8")
);

type Target = {
  key: string;
  addr: string;
  sourceKey: string;
  contractName: string;
  libraries?: Record<string, Record<string, string>>;
};

const targets: Target[] = [
  {
    key: "ConetTreasuryPeerWrappedLib",
    addr: meta.wrappedLib,
    sourceKey: "project/src/b-unit/ConetTreasuryPeerWrappedLib.sol",
    contractName: "project/src/b-unit/ConetTreasuryPeerWrappedLib.sol:ConetTreasuryPeerWrappedLib",
  },
  {
    key: "ConetTreasuryPeerStableSwapLib",
    addr: meta.stableSwapLib,
    sourceKey: "project/src/b-unit/ConetTreasuryPeerStableSwapLib.sol",
    contractName:
      "project/src/b-unit/ConetTreasuryPeerStableSwapLib.sol:ConetTreasuryPeerStableSwapLib",
  },
  {
    key: "ConetTreasuryPeerDepositLib",
    addr: meta.depositLib,
    sourceKey: "project/src/b-unit/ConetTreasuryPeerDepositLib.sol",
    contractName: "project/src/b-unit/ConetTreasuryPeerDepositLib.sol:ConetTreasuryPeerDepositLib",
  },
  {
    key: "ConetTreasuryPeerStableSwapSigLib",
    addr: meta.stableSwapSigLib,
    sourceKey: "project/src/b-unit/ConetTreasuryPeerStableSwapSigLib.sol",
    contractName:
      "project/src/b-unit/ConetTreasuryPeerStableSwapSigLib.sol:ConetTreasuryPeerStableSwapSigLib",
  },
  {
    key: "ConetTreasuryPeerStableSwapOffline",
    addr: meta.stableSwapOffline,
    sourceKey: "project/src/b-unit/ConetTreasuryPeerStableSwapOffline.sol",
    contractName:
      "project/src/b-unit/ConetTreasuryPeerStableSwapOffline.sol:ConetTreasuryPeerStableSwapOffline",
    libraries: {
      "project/src/b-unit/ConetTreasuryPeerStableSwapSigLib.sol": {
        ConetTreasuryPeerStableSwapSigLib: meta.stableSwapSigLib,
      },
    },
  },
  {
    key: "ConetTreasuryPeer",
    addr: meta.peer,
    sourceKey: "project/src/b-unit/ConetTreasuryPeer.sol",
    contractName: "project/src/b-unit/ConetTreasuryPeer.sol:ConetTreasuryPeer",
    libraries: {
      "project/src/b-unit/ConetTreasuryPeerWrappedLib.sol": {
        ConetTreasuryPeerWrappedLib: meta.wrappedLib,
      },
      "project/src/b-unit/ConetTreasuryPeerStableSwapLib.sol": {
        ConetTreasuryPeerStableSwapLib: meta.stableSwapLib,
      },
      "project/src/b-unit/ConetTreasuryPeerDepositLib.sol": {
        ConetTreasuryPeerDepositLib: meta.depositLib,
      },
    },
  },
];

function resolveImport(fromKey: string, spec: string, sources: Record<string, unknown>): string | null {
  if (sources[spec]) return spec;
  if (spec.startsWith("@") || spec.startsWith("project/")) {
    return sources[spec] ? spec : null;
  }
  const fromDir = path.posix.dirname(fromKey.replace(/^project\//, ""));
  const joined = path.posix.normalize(path.posix.join(fromDir, spec));
  const candidates = [`project/${joined}`, joined];
  for (const c of candidates) {
    if (sources[c]) return c;
  }
  return null;
}

function prune(full: any, rootKey: string) {
  const sources = full.sources as Record<string, { content: string }>;
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
  delete settings.compilationTarget;
  settings.outputSelection = {
    "*": {
      "": ["ast"],
      "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
    },
  };
  settings.remappings = [];
  return {
    language: full.language,
    sources: prunedSources,
    settings,
  };
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

async function submit(t: Target) {
  if (await isVerified(t.addr)) {
    console.log(`✅ already verified: ${t.key} ${t.addr}`);
    return;
  }
  const fullPath = path.join(__dirname, "..", "deployments", `base-${t.key}-standard-input-FULL.json`);
  const full = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
  const pruned = prune(full, t.sourceKey);
  if (t.libraries) {
    pruned.settings.libraries = t.libraries;
  }
  const outPath = path.join(__dirname, "..", "deployments", `conet-${t.key}-verify-buildinfo.json`);
  fs.writeFileSync(outPath, JSON.stringify(pruned) + "\n");
  console.log(`wrote ${outPath} sources=${Object.keys(pruned.sources).length}`);

  const form = new FormData();
  form.set("compiler_version", COMPILER);
  form.set("contract_name", t.contractName);
  form.set("autodetect_constructor_args", "true");
  form.set("license_type", "mit");
  form.set(
    "files[0]",
    new File([JSON.stringify(pruned)], `${t.key}.json`, { type: "application/json" })
  );

  const url = `${SCAN}/api/v2/smart-contracts/${t.addr}/verification/via/standard-input`;
  const res = await fetch(url, { method: "POST", body: form as any });
  const text = await res.text();
  console.log(`submit ${t.key} → HTTP ${res.status}: ${text.slice(0, 300)}`);

  for (let i = 0; i < 45; i++) {
    await new Promise((r) => setTimeout(r, 4000));
    if (await isVerified(t.addr)) {
      console.log(`✅ verified: ${t.key} ${t.addr}`);
      return;
    }
    process.stdout.write(".");
  }
  console.log(`\n⚠️ poll timeout: ${t.key} ${t.addr}`);
}

async function main() {
  for (const t of targets) {
    await submit(t);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
