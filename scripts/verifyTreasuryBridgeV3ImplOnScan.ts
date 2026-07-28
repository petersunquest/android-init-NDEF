/**
 * Verify the latest TreasuryBridgeV3 implementation on CoNET Blockscout (v2)
 * and optionally BaseScan (legacy standard-json API).
 *
 * Prereq:
 *   npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs TreasuryBridgeV3 --full
 *   npm run export:treasury-v3-verify-form
 *
 * Run:
 *   npx tsx scripts/verifyTreasuryBridgeV3ImplOnScan.ts
 *   VERIFY_CHAIN=conet|base|both npx tsx scripts/verifyTreasuryBridgeV3ImplOnScan.ts
 *
 * Env:
 *   BASESCAN_API_KEY / ETHERSCAN_API_KEY — required for Base
 *   SKIP_LOCAL_BYTECODE_CHECK=1 — skip solc precheck (not recommended)
 */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";
import { ethers } from "ethers";
import { homedir } from "os";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
/** Prefer artifact-matching VERIFY-FORM (from correct Hardhat buildInfoId); fall back to FORM. */
function resolveVerifyJson(): string {
  const candidates = [
    path.join(ROOT, "deployments", "base-TreasuryBridgeV3-standard-input-VERIFY-FORM.json"),
    path.join(ROOT, "deployments", "base-TreasuryBridgeV3-standard-input-VERIFY.json"),
    path.join(ROOT, "deployments", "base-TreasuryBridgeV3-standard-input-FULL-FORM.json"),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  throw new Error(
    "Missing verify JSON. Export from artifact buildInfoId (see scripts/exportTreasuryBridgeV3VerifyJson.mjs)",
  );
}

const SOURCE_FQN = "project/src/b-unit/TreasuryBridgeV3.sol:TreasuryBridgeV3";
const CONTRACT_SHORT = "TreasuryBridgeV3";
const COMPILER_VERSION = "v0.8.35+commit.47b9dedd";
const CONET_EXPLORER = "https://mainnet.conet.network";
const BASESCAN_API = "https://api.basescan.org/api";

type ChainKey = "base" | "conet";

function readImpl(chain: ChainKey): string {
  const p = path.join(ROOT, "deployments", `${chain}-treasury-v3.json`);
  const j = JSON.parse(fs.readFileSync(p, "utf8")) as {
    contracts?: { TreasuryBridgeV3Implementation?: string };
  };
  const addr = j.contracts?.TreasuryBridgeV3Implementation;
  if (!addr) throw new Error(`Missing implementation in ${p}`);
  return ethers.getAddress(addr);
}

function resolveSolc(): string {
  const env = process.env.SOLC_PATH?.trim();
  if (env && fs.existsSync(env)) return env;
  const cache = path.join(
    homedir(),
    "Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64",
    `solc-macosx-amd64-${COMPILER_VERSION}`,
  );
  if (fs.existsSync(cache)) return cache;
  throw new Error(`solc not found: set SOLC_PATH or install Hardhat ${COMPILER_VERSION}`);
}

function localDeployedBytecode(formJson: string): string {
  const solc = resolveSolc();
  const outPath = path.join("/tmp", `treasury-v3-verify-${Date.now()}.json`);
  const r = spawnSync(solc, ["--standard-json", formJson], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.status !== 0) {
    throw new Error(`solc failed: ${r.stderr || r.stdout?.slice(0, 2000)}`);
  }
  fs.writeFileSync(outPath, r.stdout);
  const out = JSON.parse(r.stdout) as {
    errors?: Array<{ severity?: string; formattedMessage?: string }>;
    contracts?: Record<string, Record<string, { evm?: { deployedBytecode?: { object?: string } } }>>;
  };
  const fatal = (out.errors ?? []).filter((e) => e.severity === "error");
  if (fatal.length) {
    throw new Error(fatal.map((e) => e.formattedMessage ?? "").join("\n").slice(0, 4000));
  }
  const [src, name] = SOURCE_FQN.split(":");
  const obj = out.contracts?.[src]?.[name]?.evm?.deployedBytecode?.object;
  if (!obj) throw new Error(`No deployedBytecode in solc output (see ${outPath})`);
  return obj.startsWith("0x") ? obj.toLowerCase() : `0x${obj}`.toLowerCase();
}

async function ethGetCode(rpc: string, address: string): Promise<string> {
  const code = await new ethers.JsonRpcProvider(rpc).getCode(address);
  return code.toLowerCase();
}

/** UUPS `__self = address(this)` immutables: mask impl address before comparing to compiler output. */
function maskImplImmutables(onchain: string, impl: string): string {
  const hex = impl.toLowerCase().replace(/^0x/, "");
  const body = onchain.toLowerCase().replace(/^0x/, "");
  return `0x${body.split(hex).join("0".repeat(40))}`;
}

async function assertBytecodeMatch(chain: ChainKey, address: string, local: string): Promise<void> {
  if (process.env.SKIP_LOCAL_BYTECODE_CHECK === "1") {
    console.log(`[${chain}] skip local bytecode check`);
    return;
  }
  const rpc = chain === "base" ? "https://base-rpc.conet.network" : "https://rpc1.conet.network";
  const onchain = await ethGetCode(rpc, address);
  if (onchain === "0x") throw new Error(`[${chain}] no code at ${address}`);
  const masked = maskImplImmutables(onchain, address);
  if (masked !== local) {
    throw new Error(
      `[${chain}] bytecode mismatch local=${(local.length - 2) / 2} onchain=${(onchain.length - 2) / 2} (after immutable mask)`,
    );
  }
  console.log(
    `[${chain}] local solc matches eth_getCode with UUPS immutables masked (${(onchain.length - 2) / 2} bytes)`,
  );
}

async function submitBlockscout(address: string, formJson: string): Promise<void> {
  const url = `${CONET_EXPLORER}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
  const json = fs.readFileSync(formJson, "utf8");
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", SOURCE_FQN);
  form.set("autodetect_constructor_args", "true");
  form.set("constructor_args", "");
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([json], { type: "application/json" }), "standard-input.json");

  console.log(`[conet] POST ${url}`);
  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string };
  try {
    out = JSON.parse(text) as { message?: string };
  } catch {
    throw new Error(`[conet] non-JSON HTTP ${res.status}: ${text.slice(0, 1500)}`);
  }
  console.log(`[conet]`, JSON.stringify(out));
  if (!res.ok && !/already verified/i.test(out.message ?? "")) {
    throw new Error(`[conet] verify submit failed HTTP ${res.status}`);
  }
}

async function pollBlockscout(address: string, maxAttempts = 90): Promise<void> {
  const url = `${CONET_EXPLORER}/api/v2/smart-contracts/${address}`;
  for (let i = 0; i < maxAttempts; i++) {
    const res = await fetch(url);
    const data = (await res.json()) as {
      is_verified?: boolean;
      is_partially_verified?: boolean;
      source_code?: string;
    };
    const ok =
      data.is_verified === true ||
      data.is_partially_verified === true ||
      (typeof data.source_code === "string" && data.source_code.length > 0);
    if (ok) {
      console.log(
        `[conet] verified is_verified=${data.is_verified} partial=${data.is_partially_verified} source_len=${data.source_code?.length ?? 0}`,
      );
      return;
    }
    if (i % 10 === 0) console.log(`[conet] polling verification… (${i}/${maxAttempts})`);
    await new Promise((r) => setTimeout(r, 4000));
  }
  throw new Error(`[conet] verification poll timeout for ${address}`);
}

async function submitBaseScan(address: string, formJson: string): Promise<void> {
  const apiKey = process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY;
  if (!apiKey) {
    console.warn("[base] BASESCAN_API_KEY / ETHERSCAN_API_KEY missing — skip BaseScan submit");
    console.warn(`[base] Manual: upload ${formJson} as Standard-Json-Input for ${address}`);
    console.warn(`  Contract Name: ${SOURCE_FQN}`);
    console.warn(`  Compiler: ${COMPILER_VERSION}`);
    return;
  }
  const standardJson = fs.readFileSync(formJson, "utf8");
  const params = new URLSearchParams();
  params.append("module", "contract");
  params.append("action", "verifysourcecode");
  params.append("chainid", "8453");
  params.append("contractaddress", address);
  params.append("sourceCode", standardJson);
  params.append("codeformat", "solidity-standard-json-input");
  params.append("contractname", SOURCE_FQN);
  params.append("compilerversion", COMPILER_VERSION);
  params.append("optimizationUsed", "1");
  params.append("runs", "0");
  params.append("constructorArguements", "");
  params.append("apikey", apiKey);
  params.append("licenseType", "3");

  console.log(`[base] POST BaseScan verifysourcecode ${address}`);
  const res = await fetch(BASESCAN_API, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });
  const data = (await res.json()) as { status?: string; result?: string; message?: string };
  console.log(`[base]`, JSON.stringify(data));
  if (data.status !== "1" && !/already verified/i.test(`${data.result ?? ""} ${data.message ?? ""}`)) {
    throw new Error(`[base] verify submit failed: ${data.message || data.result}`);
  }
  const guid = data.result;
  if (!guid || /already verified/i.test(guid)) return;

  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 5000));
    const check = new URLSearchParams({
      module: "contract",
      action: "checkverifystatus",
      guid,
      apikey: apiKey,
    });
    const cr = await fetch(`${BASESCAN_API}?${check}`);
    const cd = (await cr.json()) as { status?: string; result?: string };
    console.log(`[base] poll`, cd.status, cd.result);
    if (cd.status === "1" || /Pass|Already Verified/i.test(cd.result ?? "")) return;
    if (/Fail|Error/i.test(cd.result ?? "") && !/Pending/i.test(cd.result ?? "")) {
      throw new Error(`[base] verify failed: ${cd.result}`);
    }
  }
  throw new Error(`[base] verification poll timeout`);
}

async function main() {
  const formJson = resolveVerifyJson();
  console.log("verify JSON:", formJson);
  const which = (process.env.VERIFY_CHAIN || "both").toLowerCase();
  const chains: ChainKey[] =
    which === "base" ? ["base"] : which === "conet" ? ["conet"] : ["conet", "base"];

  console.log("Local solc compile of verify JSON…");
  const local = localDeployedBytecode(formJson);
  console.log(`local deployedBytecode ${(local.length - 2) / 2} bytes`);

  for (const chain of chains) {
    const address = readImpl(chain);
    console.log(`\n=== ${chain} impl ${address} ===`);
    await assertBytecodeMatch(chain, address, local);
    if (chain === "conet") {
      await submitBlockscout(address, formJson);
      await pollBlockscout(address, Number(process.env.CONET_VERIFY_POLL_MAX || 90));
      console.log(`${CONET_EXPLORER}/address/${address}#code`);
    } else {
      await submitBaseScan(address, formJson);
      console.log(`https://basescan.org/address/${address}#code`);
    }
  }
  console.log("\nDone.", CONTRACT_SHORT);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
