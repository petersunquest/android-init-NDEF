/**
 * 在 CoNET Blockscout 验证 ConetTreasury / FactoryERC20（full standard JSON，viaIR）。
 *
 * 默认 API 指向 **索引 mainnet-rpc1 的 Blockscout**（`mainnet.conet.network/api`）；
 * UI 链接使用 `https://scan.conet.network`（若 scan 与 mainnet API 未共用同一索引，须先让 scan 的
 * `ETHEREUM_JSONRPC_HTTP_URL` 指向 `https://mainnet-rpc1.conet.network` 并 reindex，否则 scan 页仍显示 EOA）。
 *
 * 环境变量:
 *   CONET_BLOCKSCOUT_API — 默认 https://mainnet.conet.network/api
 *   CONET_BLOCKSCOUT_UI — 默认 https://scan.conet.network
 *
 * 运行:
 *   npx tsx scripts/verifyConetTreasuryOnScan.ts
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";
import { CONET_TREASURY_INITIAL_MINER } from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://scan.conet.network").replace(/\/$/, "");
const SOURCE_KEY = "project/src/b-unit/conetTreasury.sol";

type VerifyTarget = {
  label: string;
  address: string;
  contractName: "ConetTreasury" | "FactoryERC20";
  constructorTypes: string[];
  constructorValues: unknown[];
};

function loadTreasuryTargets(): VerifyTarget[] {
  const treasuryPath = path.join(root, "deployments", "conet-ConetTreasury.json");
  const wrappedPath = path.join(root, "deployments", "conetTreasury-wrapped-base-usdc-meta.json");
  if (!fs.existsSync(treasuryPath)) throw new Error("缺少 deployments/conet-ConetTreasury.json");

  const treasuryData = JSON.parse(fs.readFileSync(treasuryPath, "utf-8"));
  const treasuryAddr = treasuryData.contracts?.ConetTreasury?.address as string;
  const conetUsdc = treasuryData.contracts?.ConetTreasury?.conetUsdc as string;
  if (!treasuryAddr || !conetUsdc) throw new Error("conet-ConetTreasury.json 缺少地址");

  const targets: VerifyTarget[] = [
    {
      label: "ConetTreasury",
      address: treasuryAddr,
      contractName: "ConetTreasury",
      constructorTypes: ["address"],
      constructorValues: [CONET_TREASURY_INITIAL_MINER],
    },
    {
      label: "conetUSDC",
      address: conetUsdc,
      contractName: "FactoryERC20",
      constructorTypes: ["string", "string", "uint8", "address"],
      constructorValues: ["USD Coin", "USDC", 6, treasuryAddr],
    },
  ];

  if (fs.existsSync(wrappedPath)) {
    const wrapped = JSON.parse(fs.readFileSync(wrappedPath, "utf-8")).predictedWrapped as string | undefined;
    if (wrapped) {
      targets.push({
        label: "wrappedBaseUsdc",
        address: wrapped,
        contractName: "FactoryERC20",
        constructorTypes: ["string", "string", "uint8", "address"],
        constructorValues: ["USD Coin", "USDC", 6, treasuryAddr],
      });
    }
  }

  return targets;
}

function loadFullStandardInput(): { json: string; compilerVersion: string } {
  const biDir = path.join(root, "artifacts", "build-info");
  const files = fs.readdirSync(biDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  for (const f of files) {
    const bi = JSON.parse(fs.readFileSync(path.join(biDir, f), "utf-8")) as {
      input?: { language: string; settings: unknown; sources: Record<string, unknown> };
      solcLongVersion?: string;
    };
    if (!bi.input?.sources?.[SOURCE_KEY]) continue;
    const v = bi.solcLongVersion ?? "0.8.33+commit.64118f21";
    return {
      json: JSON.stringify({
        language: bi.input.language,
        settings: bi.input.settings,
        sources: bi.input.sources,
      }),
      compilerVersion: v.startsWith("v") ? v : `v${v}`,
    };
  }
  throw new Error("未找到 conetTreasury build-info；请先 npm run compile");
}

async function checkVerified(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (res.status === 404) return false;
  if (!res.ok) return false;
  const data = (await res.json()) as { is_verified?: boolean; source_code?: string };
  return Boolean(data.is_verified || data.source_code);
}

async function submitVerify(target: VerifyTarget, standardJson: string, compilerVersion: string): Promise<void> {
  const encoded = AbiCoder.defaultAbiCoder().encode(target.constructorTypes, target.constructorValues);
  const constructorArgs = encoded.startsWith("0x") ? encoded.slice(2) : encoded;

  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", compilerVersion);
  form.set("contract_name", target.contractName);
  form.set("autodetect_constructor_args", "false");
  form.set("constructor_args", constructorArgs);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST ${url}`);
  console.log(`  ${target.label} (${target.contractName})`);

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
    throw new Error(`${target.label} 验证提交失败 HTTP ${res.status}`);
  }
}

async function waitVerified(address: string, label: string, attempts = 30): Promise<boolean> {
  for (let i = 0; i < attempts; i++) {
    if (await checkVerified(address)) {
      console.log(`  ✅ ${label} 已验证: ${BLOCKSCOUT_UI}/address/${address}#code`);
      return true;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.warn(`  ⚠️ ${label} 验证轮询超时`);
  return false;
}

async function main() {
  const { json, compilerVersion } = loadFullStandardInput();
  const targets = loadTreasuryTargets();

  console.log("CoNET Blockscout 合约验证");
  console.log("API:", BLOCKSCOUT_API);
  console.log("UI:", BLOCKSCOUT_UI);
  console.log("compiler:", compilerVersion);
  console.log("standard-input bytes:", json.length);

  for (const target of targets) {
    if (await checkVerified(target.address)) {
      console.log(`\n⏭️ ${target.label} 已验证: ${BLOCKSCOUT_UI}/address/${target.address}#code`);
      continue;
    }
    await submitVerify(target, json, compilerVersion);
    await waitVerified(target.address, target.label);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
