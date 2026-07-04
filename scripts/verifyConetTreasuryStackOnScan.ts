/**
 * 在 CoNET Blockscout 验证 ConetTreasury 栈（Treasury / Peer / FactoryERC20 / BUint / GB）。
 *
 * API: https://mainnet.conet.network/api
 * UI:  https://scan.conet.network
 *
 * 运行: npx tsx scripts/verifyConetTreasuryStackOnScan.ts
 *
 * 环境变量:
 *   CONET_BLOCKSCOUT_API / CONET_BLOCKSCOUT_UI
 *   CONET_TREASURY / CONET_TREASURY_PEER — 覆盖验证地址
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";
import {
  CONET_MAINNET_RPC_URL,
  CONET_TREASURY_CREATE2_PREDICTED,
  CONET_TREASURY_INITIAL_MINER,
  CONET_TREASURY_PEER_CREATE2_PREDICTED,
  CONET_USDC,
  WRAPPED_CONET_CREATE2_PREDICTED,
} from "./conetTreasuryDeployConstants.js";
import { CONET_USDC_UUPS_IMPL_PREDICTED } from "./erc20UupsDeployConstants.js";
import {
  BASESCAN_COMPILER_VERSION,
  exportBasescanStandardJsonFromRoot,
} from "./basescanStandardJsonShared.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");

type VerifyTarget = {
  label: string;
  address: string;
  contractName: string;
  sourceKey: string;
  constructorTypes: string[];
  constructorValues: unknown[];
};

function readJsonMeta(file: string): Record<string, unknown> | null {
  const p = path.join(root, "deployments", file);
  if (!fs.existsSync(p)) return null;
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

function loadTargets(): VerifyTarget[] {
  const treasuryAddr =
    process.env.CONET_TREASURY ||
    readJsonMeta("conetTreasury-create2-meta.json")?.predictedAddress ||
    CONET_TREASURY_CREATE2_PREDICTED;
  const peerAddr =
    process.env.CONET_TREASURY_PEER ||
    readJsonMeta("conetTreasuryPeer-create2-meta.json")?.predictedAddress ||
    CONET_TREASURY_PEER_CREATE2_PREDICTED;

  const addrJson = readJsonMeta("conet-addresses.json");
  const conetUsdc = (addrJson?.conetUsdc as string) || CONET_USDC;
  const wrappedConet = (addrJson?.wrappedConet as string) || WRAPPED_CONET_CREATE2_PREDICTED;
  const usdcImpl =
    (addrJson?.ConetUsdcUupsImpl as string) || CONET_USDC_UUPS_IMPL_PREDICTED;

  const targets: VerifyTarget[] = [
    {
      label: "ConetTreasury",
      address: String(treasuryAddr),
      contractName: "ConetTreasury",
      sourceKey: "project/src/b-unit/conetTreasury.sol",
      constructorTypes: ["address"],
      constructorValues: [CONET_TREASURY_INITIAL_MINER],
    },
    {
      label: "ConetTreasuryPeer",
      address: String(peerAddr),
      contractName: "ConetTreasuryPeer",
      sourceKey: "project/src/b-unit/ConetTreasuryPeer.sol",
      constructorTypes: ["address"],
      constructorValues: [treasuryAddr],
    },
    {
      label: "wCNET",
      address: String(wrappedConet),
      contractName: "FactoryERC20",
      sourceKey: "project/src/b-unit/FactoryERC20.sol",
      constructorTypes: ["string", "string", "uint8", "address"],
      constructorValues: ["Wrapped CoNET", "wCNET", 18, treasuryAddr],
    },
    {
      label: "CONET-USDC-impl",
      address: String(usdcImpl),
      contractName: "FactoryERC20Upgradeable",
      sourceKey: "project/src/b-unit/FactoryERC20Upgradeable.sol",
      constructorTypes: [],
      constructorValues: [],
    },
  ];

  // CONET-USDC proxy (ERC1967) 用 scripts/verifyErc20UupsUsdcConet.ts 单独验证
  void conetUsdc;

  return targets;
}

/**
 * 递归依赖剪枝导出 Standard JSON（避免 mainnet.conet.network nginx 413）。
 * 见 standard-json-export-source-of-truth.mdc / beamio-base-basescan-verify.mdc。
 */
function loadStandardInputForSource(sourceKey: string): { json: string; compilerVersion: string } {
  const { standardJson } = exportBasescanStandardJsonFromRoot(root, sourceKey);
  return {
    json: JSON.stringify(standardJson),
    compilerVersion: `v${BASESCAN_COMPILER_VERSION}`,
  };
}

async function checkVerified(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (res.status === 404) return false;
  if (!res.ok) return false;
  const data = (await res.json()) as { is_verified?: boolean; source_code?: string };
  return Boolean(data.is_verified || data.source_code);
}

async function rpcHasCode(address: string): Promise<boolean> {
  const rpc = process.env.CONET_RPC_URL || CONET_MAINNET_RPC_URL;
  const res = await fetch(rpc, {
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

async function addressHasContractCode(address: string): Promise<boolean> {
  if (await rpcHasCode(address)) return true;
  return checkHasCode(address);
}

async function waitBlockscoutContract(address: string, label: string, attempts = 12): Promise<boolean> {
  for (let i = 0; i < attempts; i++) {
    const res = await fetch(`${BLOCKSCOUT_API}/v2/addresses/${address}`);
    if (res.ok) {
      const data = (await res.json()) as { is_contract?: boolean };
      if (data.is_contract) {
        console.log(`  Blockscout 已索引 ${label}`);
        return true;
      }
    }
    if (i === 0) {
      console.log(`  等待 Blockscout 索引 ${label}（RPC 已有 code）…`);
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
  console.warn(`  ⚠️ Blockscout 仍未索引 ${label}；验证 API 可能返回 404，请稍后重跑本脚本`);
  return false;
}

async function checkHasCode(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/addresses/${address}`);
  if (!res.ok) return false;
  const data = (await res.json()) as { is_contract?: boolean };
  return Boolean(data.is_contract);
}

async function submitVerify(
  target: VerifyTarget,
  standardJson: string,
  compilerVersion: string
): Promise<void> {
  const encoded = AbiCoder.defaultAbiCoder().encode(target.constructorTypes, target.constructorValues);
  const constructorArgs = encoded.startsWith("0x") ? encoded.slice(2) : encoded;

  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", compilerVersion);
  form.set("contract_name", `${target.sourceKey}:${target.contractName}`);
  form.set("autodetect_constructor_args", "false");
  form.set("constructor_args", constructorArgs);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST ${target.label} @ ${target.address}`);
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
    if (/not a smart-contract/i.test(out.message ?? "")) {
      console.warn(
        `  ⚠️ ${target.label}: Blockscout 尚未索引该地址（当前 API 链高与 RPC 不一致时常见）。` +
          `请确认 scan 的 ETHEREUM_JSONRPC_HTTP_URL 指向 ${process.env.CONET_RPC_URL || CONET_MAINNET_RPC_URL} 并重跑本脚本。`
      );
      return;
    }
    throw new Error(`${target.label} 验证提交失败 HTTP ${res.status}`);
  }
}

async function waitVerified(address: string, label: string, attempts = 40): Promise<boolean> {
  for (let i = 0; i < attempts; i++) {
    if (await checkVerified(address)) {
      console.log(`  ✅ ${label}: ${BLOCKSCOUT_UI}/address/${address}#code`);
      return true;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.warn(`  ⚠️ ${label} 验证轮询超时`);
  return false;
}

async function main() {
  const targets = loadTargets();
  console.log("CoNET Blockscout stack verification");
  console.log("API:", BLOCKSCOUT_API);
  console.log("UI:", BLOCKSCOUT_UI);

  const inputCache = new Map<string, { json: string; compilerVersion: string }>();

  for (const target of targets) {
    const hasCode = await addressHasContractCode(target.address);
    if (!hasCode) {
      console.log(`\n⏭️ ${target.label} 链上无合约，跳过: ${target.address}`);
      continue;
    }

    if (await checkVerified(target.address)) {
      console.log(`\n⏭️ ${target.label} 已验证: ${BLOCKSCOUT_UI}/address/${target.address}#code`);
      continue;
    }

    if (!inputCache.has(target.sourceKey)) {
      inputCache.set(target.sourceKey, loadStandardInputForSource(target.sourceKey));
    }
    const { json, compilerVersion } = inputCache.get(target.sourceKey)!;
    await waitBlockscoutContract(target.address, target.label);
    await submitVerify(target, json, compilerVersion);
    await waitVerified(target.address, target.label);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
