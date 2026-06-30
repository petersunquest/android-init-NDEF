/**
 * 在 CoNET Blockscout / Base Basescan 验证 GBToken（剪枝 Standard JSON，避免 413）。
 *
 * 前置: npm run compile && npx tsx scripts/exportGBTokenStandardJson.ts
 *
 * 运行:
 *   npx tsx scripts/verifyGBTokenOnScan.ts conet
 *   BASESCAN_API_KEY=... npx tsx scripts/verifyGBTokenOnScan.ts base
 */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { getAddress } from "ethers";
import { GBTOKEN_CREATE2_PREDICTED } from "./gbTokenDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const COMPILER_VERSION = "v0.8.35+commit.47b9dedd";
const CONTRACT_FILE = "project/src/b-unit/GBToken.sol:GBToken";
const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://scan.conet.network").replace(/\/$/, "");
const BASESCAN_API = "https://api.etherscan.io/v2/api";
const CHAIN_ID = 8453;

function resolveAddress(): string {
  if (process.env.GB_TOKEN?.trim()) return getAddress(process.env.GB_TOKEN.trim());
  const metaPath = path.join(root, "deployments", "gbToken-create2-meta.json");
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8")) as { predictedAddress?: string };
    if (meta.predictedAddress) return getAddress(meta.predictedAddress);
  }
  return GBTOKEN_CREATE2_PREDICTED;
}

function loadJsonAndConstructorArgs(): { json: string; constructorArgs: string } {
  const jsonPath = path.join(root, "deployments", "base-GBToken-standard-input-FULL-FORM.json");
  const metaPath = path.join(root, "deployments", "base-GBToken-basescan-verify-meta.txt");
  if (!fs.existsSync(jsonPath)) {
    throw new Error("缺少 standard JSON；请先 npx tsx scripts/exportGBTokenStandardJson.ts");
  }
  const json = fs.readFileSync(jsonPath, "utf-8");
  const meta = fs.readFileSync(metaPath, "utf-8");
  const m = meta.match(/Constructor Args ABI-encoded:\s*(\S+)/);
  const constructorArgs = m?.[1] && m[1] !== "(none)" ? m[1] : "";
  return { json, constructorArgs };
}

async function waitVerifyConet(address: string): Promise<void> {
  for (let i = 0; i < 40; i++) {
    const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
    if (res.ok) {
      const data = (await res.json()) as { is_verified?: boolean; source_code?: string };
      if (data.is_verified || data.source_code) {
        console.log("✅ CoNET 已验证:", `${BLOCKSCOUT_UI}/address/${address}#code`);
        return;
      }
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.warn("⚠️ CoNET 验证轮询超时，请稍后刷新 scan");
}

async function verifyConet(address: string, json: string, constructorArgs: string): Promise<void> {
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", CONTRACT_FILE);
  form.set("autodetect_constructor_args", "false");
  form.set("constructor_args", constructorArgs);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([json], { type: "application/json" }), "standard-input.json");

  console.log("POST", url, `(${(json.length / 1024).toFixed(1)} KB)`);
  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string };
  try {
    out = JSON.parse(text) as { message?: string };
  } catch {
    console.error(text.slice(0, 2000));
    throw new Error(`CoNET: HTTP ${res.status}`);
  }
  console.log("HTTP", res.status, out.message ?? text.slice(0, 300));
  if (!res.ok || !/verification started|already verified/i.test(out.message ?? "")) {
    throw new Error(`CoNET 验证失败: ${out.message ?? res.status}`);
  }
  await waitVerifyConet(address);
}

async function waitVerifyBase(guid: string, apiKey: string): Promise<string> {
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const url =
      `${BASESCAN_API}?chainid=${CHAIN_ID}&module=contract&action=checkverifystatus` +
      `&guid=${encodeURIComponent(guid)}&apikey=${encodeURIComponent(apiKey)}`;
    const res = await fetch(url);
    const data = (await res.json()) as { status?: string; result?: string };
    const result = String(data.result ?? "");
    if (/pass|already verified/i.test(result)) return result;
    if (/fail/i.test(result)) return result;
  }
  return "Pending (poll timeout)";
}

async function verifyBase(address: string, json: string, constructorArgs: string): Promise<void> {
  const apiKey = process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY;
  if (!apiKey) throw new Error("Base 验证需要 BASESCAN_API_KEY 或 ETHERSCAN_API_KEY");

  const params = new URLSearchParams();
  params.append("chainid", String(CHAIN_ID));
  params.append("module", "contract");
  params.append("action", "verifysourcecode");
  params.append("contractaddress", address);
  params.append("sourceCode", json);
  params.append("codeformat", "solidity-standard-json-input");
  params.append("contractname", CONTRACT_FILE);
  params.append("compilerversion", COMPILER_VERSION);
  params.append("constructorArguements", constructorArgs);
  params.append("licenseType", "3");
  params.append("apikey", apiKey);

  const res = await fetch(BASESCAN_API, { method: "POST", body: params });
  const data = (await res.json()) as { status?: string; message?: string; result?: string };
  console.log("Basescan submit:", data.status, data.message, data.result);
  if (data.status !== "1" || !data.result) {
    throw new Error(`Base 验证提交失败: ${data.message} ${data.result ?? ""}`);
  }
  const final = await waitVerifyBase(data.result, apiKey);
  console.log("Basescan result:", final);
  if (/pass|already verified/i.test(final)) {
    console.log("✅ Base 已验证: https://basescan.org/address/" + address + "#code");
  }
}

async function main() {
  const chain = (process.argv[2] || "conet").toLowerCase();
  const address = resolveAddress();
  const { json, constructorArgs } = loadJsonAndConstructorArgs();
  console.log("GBToken:", address, "chain:", chain, "compiler:", COMPILER_VERSION);

  if (chain === "conet" || chain === "224422") {
    await verifyConet(address, json, constructorArgs);
    return;
  }
  if (chain === "base" || chain === "8453") {
    await verifyBase(address, json, constructorArgs);
    return;
  }
  throw new Error(`未知链: ${chain}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
