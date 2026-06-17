/**
 * Blockscout Standard JSON 验证 CoNET 上 CREATE2 BeamioOracle（224422）。
 *
 * 前置:
 *   npm run clean && npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BeamioOracle --full
 *   node scripts/exportBeamioStackBaseScanFormJson.mjs
 *
 * 运行:
 *   npx tsx scripts/verifyBeamioOracleOnConetScan.ts
 *
 * 环境变量:
 *   CONET_BLOCKSCOUT_API — 默认 https://scan.conet.network/api
 *   CONET_BLOCKSCOUT_UI  — 默认 https://scan.conet.network
 *   BEAMIO_ORACLE_ADDRESS — 覆盖验证地址
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";
import {
  BEAMIO_ORACLE_ADMIN,
  BEAMIO_ORACLE_PREDICTED,
} from "./oracleDeployConstants.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://scan.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://scan.conet.network").replace(/\/$/, "");
const CONET_RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const COMPILER_VERSION = "v0.8.33+commit.64118f21";
const CONTRACT_NAME = "project/src/BeamioUserCard/BeamioOracle.sol:BeamioOracle";
const FORM_JSON = path.join(root, "deployments/base-BeamioOracle-standard-input-FULL-FORM.json");

function resolveOracleAddress(): string {
  const env = process.env.BEAMIO_ORACLE_ADDRESS?.trim();
  if (env) return env;
  const metaPath = path.join(root, "deployments/beamioOracle-create2-meta.json");
  if (fs.existsSync(metaPath)) {
    const j = JSON.parse(fs.readFileSync(metaPath, "utf-8")) as {
      predictedOracle?: string;
      deployments?: Record<string, { oracle?: string }>;
    };
    const from224422 = j.deployments?.["224422"]?.oracle;
    if (from224422) return from224422;
    if (j.predictedOracle) return j.predictedOracle;
  }
  return BEAMIO_ORACLE_PREDICTED;
}

function constructorArgsHex(): string {
  return AbiCoder.defaultAbiCoder().encode(["address"], [BEAMIO_ORACLE_ADMIN]).slice(2);
}

async function rpcHasCode(address: string): Promise<boolean> {
  const res = await fetch(CONET_RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_getCode",
      params: [address, "latest"],
      id: 1,
    }),
  });
  const data = (await res.json()) as { result?: string };
  return typeof data.result === "string" && data.result.length > 2;
}

async function checkVerified(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (!res.ok) return false;
  const data = (await res.json()) as { is_verified?: boolean; source_code?: string | null };
  return Boolean(data.is_verified || data.source_code);
}

async function submitVerify(address: string, standardJson: string, contractName: string): Promise<void> {
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", contractName);
  form.set("autodetect_constructor_args", "false");
  form.set("constructor_args", constructorArgsHex());
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`POST ${url}`);
  console.log("  contract_name:", contractName);
  console.log("  constructor_args:", constructorArgsHex());

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string };
  try {
    out = JSON.parse(text) as { message?: string };
  } catch {
    console.error(text.slice(0, 2000));
    throw new Error(`非 JSON 响应 HTTP ${res.status}`);
  }
  console.log(" ", JSON.stringify(out));
  if (!res.ok || !/verification started|already verified/i.test(out.message ?? "")) {
    throw new Error(`验证提交失败 HTTP ${res.status}: ${out.message ?? text.slice(0, 500)}`);
  }
}

async function waitVerified(address: string, attempts = 40): Promise<boolean> {
  for (let i = 0; i < attempts; i++) {
    if (await checkVerified(address)) {
      console.log(`✅ 已验证: ${BLOCKSCOUT_UI}/address/${address}#code`);
      return true;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.warn("⚠️ 验证轮询超时，请稍后在 Blockscout 查看");
  return false;
}

async function main() {
  const address = resolveOracleAddress();
  if (!fs.existsSync(FORM_JSON)) {
    throw new Error(`缺少 ${FORM_JSON}；请先 exportBeamioStackBaseScanFormJson.mjs`);
  }

  console.log("CoNET BeamioOracle Blockscout verification");
  console.log("Address:", address);
  console.log("RPC:", CONET_RPC);
  console.log("API:", BLOCKSCOUT_API);
  console.log("JSON:", FORM_JSON, `(${(fs.statSync(FORM_JSON).size / 1024).toFixed(1)} KB)`);

  if (!(await rpcHasCode(address))) {
    throw new Error(`链上无 bytecode: ${address}`);
  }

  if (await checkVerified(address)) {
    console.log(`⏭️ 已验证: ${BLOCKSCOUT_UI}/address/${address}#code`);
    return;
  }

  const standardJson = fs.readFileSync(FORM_JSON, "utf-8");
  const names = [CONTRACT_NAME, "BeamioOracle"];

  for (const name of names) {
    try {
      await submitVerify(address, standardJson, name);
      await waitVerified(address);
      return;
    } catch (e) {
      console.warn(`contract_name=${name} 失败:`, (e as Error).message);
      if (name === names[names.length - 1]) throw e;
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
