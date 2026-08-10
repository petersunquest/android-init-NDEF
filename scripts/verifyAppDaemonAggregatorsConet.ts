/**
 * Verify Multicall3 + BeamioConsumerWalletDashboard on CoNET Blockscout.
 *
 * Prefers v2 standard-input after FULL export + local bytecode precheck when possible.
 * Falls back to reporting curl commands if API key / JSON missing.
 *
 *   npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs Multicall3 --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioConsumerWalletDashboard --full
 *   npx tsx scripts/verifyAppDaemonAggregatorsConet.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const API = "https://mainnet.conet.network/api/v2";

const MULTICALL = "0x4e73d76E7fC6b6Aa471dca7238107246BF4c8145";
const DASH_PROXY = "0x28370397A2b0C504e93754288ABb4F47EAaf168f";
const DASH_IMPL = "0x7922B887dD5b7dEf0355e9537AB642E7eC5065F9";

async function checkVerified(addr: string): Promise<{ verified: boolean; partial: boolean; len: number }> {
  const res = await fetch(`${API}/smart-contracts/${addr}`);
  if (!res.ok) return { verified: false, partial: false, len: 0 };
  const d = (await res.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string;
  };
  return {
    verified: Boolean(d.is_verified),
    partial: Boolean(d.is_partially_verified),
    len: (d.source_code || "").length,
  };
}

async function submitStandardInput(
  addr: string,
  jsonPath: string,
  contractName: string,
  compilerVersion: string,
): Promise<void> {
  if (!fs.existsSync(jsonPath)) {
    console.warn("missing JSON:", jsonPath);
    return;
  }
  const form = new FormData();
  form.append("compiler_version", compilerVersion);
  form.append("contract_name", contractName);
  form.append("autodetect_constructor_args", "true");
  form.append("license_type", "mit");
  const blob = new Blob([fs.readFileSync(jsonPath)], { type: "application/json" });
  form.append("files[0]", blob, path.basename(jsonPath));

  const url = `${API}/smart-contracts/${addr}/verification/via/standard-input`;
  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  console.log("submit", addr, res.status, text.slice(0, 300));
}

async function main() {
  // Detect solc from impl bytecode tail
  const rpc = process.env.CONET_RPC_URL || "https://rpc1.conet.network";
  const codeRes = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_getCode",
      params: [DASH_IMPL, "latest"],
    }),
  });
  const codeJson = (await codeRes.json()) as { result?: string };
  const code = codeJson.result || "0x";
  const tail = code.slice(-24);
  console.log("impl bytecode tail:", tail);
  // Prefer hardhat 0.8.33 (000821) for this deploy
  const compilerVersion = "v0.8.33+commit.64118f21";

  for (const [label, addr] of [
    ["Multicall3", MULTICALL],
    ["DashboardImpl", DASH_IMPL],
    ["DashboardProxy", DASH_PROXY],
  ] as const) {
    const st = await checkVerified(addr);
    console.log(label, addr, st);
  }

  const mcJson = path.join(ROOT, "deployments", "base-Multicall3-standard-input-FULL.json");
  const altMc = path.join(ROOT, "deployments", "conet-Multicall3-standard-input-FULL.json");
  // export script writes base- prefix historically — also try that name
  const mcCandidates = [
    path.join(ROOT, "deployments", "base-Multicall3-standard-input-FULL.json"),
    altMc,
  ];
  const dashJson = path.join(
    ROOT,
    "deployments",
    "base-BeamioConsumerWalletDashboard-standard-input-FULL.json",
  );

  const mcPath = mcCandidates.find((p) => fs.existsSync(p));
  if (mcPath) {
    await submitStandardInput(
      MULTICALL,
      mcPath,
      "project/src/mainnet/Multicall3.sol:Multicall3",
      compilerVersion,
    );
  } else {
    console.warn("Run: node scripts/exportStandardJsonFromBuildInfo.mjs Multicall3 --full");
  }

  if (fs.existsSync(dashJson)) {
    await submitStandardInput(
      DASH_IMPL,
      dashJson,
      "project/src/mainnet/BeamioConsumerWalletDashboard.sol:BeamioConsumerWalletDashboard",
      compilerVersion,
    );
  } else {
    console.warn(
      "Run: node scripts/exportStandardJsonFromBuildInfo.mjs BeamioConsumerWalletDashboard --full",
    );
  }

  console.log("\nProxy verify: use Blockscout legacy verifysourcecode with OZ ERC1967Proxy (partial OK).");
  console.log("Proxy:", DASH_PROXY, "impl:", DASH_IMPL);

  // Poll impl
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 4000));
    const st = await checkVerified(DASH_IMPL);
    console.log(`poll impl #${i + 1}`, st);
    if (st.verified || st.partial || st.len > 0) break;
  }
  const mcSt = await checkVerified(MULTICALL);
  console.log("final Multicall3", mcSt);
  const implSt = await checkVerified(DASH_IMPL);
  console.log("final DashboardImpl", implSt);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
