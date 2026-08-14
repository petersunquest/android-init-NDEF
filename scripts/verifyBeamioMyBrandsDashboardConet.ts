/**
 * Verify BeamioMyBrandsDashboard on CoNET Blockscout.
 *
 *   npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioMyBrandsDashboard --full
 *   npx tsx scripts/verifyBeamioMyBrandsDashboardConet.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const API = "https://mainnet.conet.network/api/v2";
const DASH_OUT = path.join(ROOT, "deployments", "conet-BeamioMyBrandsDashboard.json");

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
  if (!fs.existsSync(DASH_OUT)) {
    throw new Error(`Missing ${DASH_OUT} — deploy first`);
  }
  const dash = JSON.parse(fs.readFileSync(DASH_OUT, "utf-8")) as {
    proxy: string;
    implementation: string;
  };
  const DASH_PROXY = dash.proxy;
  const DASH_IMPL = dash.implementation;

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
  // 000823 => 0.8.35; 000821 => 0.8.33
  let compilerVersion = "v0.8.35+commit.47b9dedd";
  if (tail.includes("000821")) compilerVersion = "v0.8.33+commit.64118f21";
  console.log("compilerVersion:", compilerVersion);

  for (const [label, addr] of [
    ["MyBrandsImpl", DASH_IMPL],
    ["MyBrandsProxy", DASH_PROXY],
  ] as const) {
    const st = await checkVerified(addr);
    console.log(label, addr, st);
  }

  const dashJson = path.join(
    ROOT,
    "deployments",
    "base-BeamioMyBrandsDashboard-standard-input-FULL.json",
  );

  if (fs.existsSync(dashJson)) {
    await submitStandardInput(
      DASH_IMPL,
      dashJson,
      "project/src/mainnet/BeamioMyBrandsDashboard.sol:BeamioMyBrandsDashboard",
      compilerVersion,
    );
  } else {
    console.warn("Run: node scripts/exportStandardJsonFromBuildInfo.mjs BeamioMyBrandsDashboard --full");
  }

  console.log("\nProxy verify: Blockscout legacy verifysourcecode with OZ ERC1967Proxy (partial OK).");
  console.log("Proxy:", DASH_PROXY, "impl:", DASH_IMPL);

  const pollMax = Number(process.env.CONET_VERIFY_POLL_MAX || "45");
  for (let i = 0; i < pollMax; i++) {
    await new Promise((r) => setTimeout(r, 4000));
    const st = await checkVerified(DASH_IMPL);
    console.log(`poll impl #${i + 1}`, st);
    if (st.verified || st.partial || st.len > 0) break;
  }
  const implSt = await checkVerified(DASH_IMPL);
  console.log("final MyBrandsImpl", implSt);

  // Update deployment JSON verification note
  const prev = JSON.parse(fs.readFileSync(DASH_OUT, "utf-8"));
  prev.verification = {
    implementation: implSt.verified
      ? "verified (Blockscout v2)"
      : implSt.partial || implSt.len > 0
        ? "partial verified (Blockscout v2)"
        : "pending",
    proxy: "verify via legacy ERC1967Proxy (partial OK)",
    proxyExplorer: `https://mainnet.conet.network/address/${DASH_PROXY}`,
  };
  fs.writeFileSync(DASH_OUT, JSON.stringify(prev, null, 2) + "\n");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
