/**
 * CoNET Blockscout v2 standard-input verification for BeamioUserCardMembershipGateLib.
 *
 * Prerequisite:
 *   npm run clean && npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardMembershipGateLib --full
 *   node scripts/exportConetMembershipGateLibVerifyBuildinfo.mjs
 *
 * Run:
 *   CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyConetMembershipGateLibOnScan.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { getAddress } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(
  /\/$/,
  "",
);
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");
const COMPILER = process.env.CONET_SOLC_VERSION || "v0.8.35+commit.47b9dedd";
const POLL_MAX = Number(process.env.CONET_VERIFY_POLL_MAX || "90");

const VERIFY_JSON = path.join(root, "deployments/conet-MembershipGateLib-verify-buildinfo.json");
const CONTRACT_NAME =
  "project/src/BeamioUserCard/BeamioUserCardMembershipGateLib.sol:BeamioUserCardMembershipGateLib";

function loadAddress(): string {
  const addrPath = path.join(root, "deployments/conet-addresses.json");
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, string>;
  const raw = data.beamioUserCardMembershipGateLib;
  if (!raw) throw new Error("beamioUserCardMembershipGateLib missing in conet-addresses.json");
  return getAddress(raw);
}

async function checkVerified(address: string): Promise<{ ok: boolean; partial: boolean }> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (!res.ok) return { ok: false, partial: false };
  const data = (await res.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string | null;
  };
  const ok = Boolean(
    data.is_verified || data.is_partially_verified || (data.source_code && data.source_code.length > 0),
  );
  return { ok, partial: Boolean(data.is_partially_verified) };
}

async function submit(address: string): Promise<void> {
  if (!fs.existsSync(VERIFY_JSON)) {
    throw new Error(`Missing ${VERIFY_JSON} — run exportConetMembershipGateLibVerifyBuildinfo.mjs first`);
  }
  const standardJson = JSON.parse(fs.readFileSync(VERIFY_JSON, "utf-8")) as object;
  const json = JSON.stringify(standardJson);
  console.log(`POST MembershipGateLib @ ${address} (json=${json.length} bytes)`);

  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER);
  form.set("contract_name", CONTRACT_NAME);
  form.set("autodetect_constructor_args", "true");
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([json], { type: "application/json" }), "standard-input.json");

  const res = await fetch(url, { method: "POST", body: form });
  const data = (await res.json().catch(() => ({}))) as { message?: string };
  console.log(" ", JSON.stringify(data));
  if (!res.ok || !/verification started|already verified/i.test(data.message ?? "")) {
    throw new Error(`Submit failed: ${data.message ?? res.status}`);
  }
}

async function waitVerified(address: string): Promise<boolean> {
  for (let i = 0; i < POLL_MAX; i++) {
    const { ok, partial } = await checkVerified(address);
    if (ok) {
      console.log(`  ✅ verified${partial ? " (partial)" : ""}: ${BLOCKSCOUT_UI}/address/${address}#code`);
      return true;
    }
    await new Promise((r) => setTimeout(r, 4000));
  }
  console.warn("  ⚠️ poll timeout");
  return false;
}

async function main() {
  const address = loadAddress();
  console.log("CoNET MembershipGateLib verify @", address);
  console.log("API:", BLOCKSCOUT_API);

  const pre = await checkVerified(address);
  if (pre.ok) {
    console.log("⏭️ already verified");
    return;
  }

  await submit(address);
  const ok = await waitVerified(address);
  if (!ok) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
