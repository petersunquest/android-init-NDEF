/**
 * 在 CoNET Blockscout (scan.conet.network) 验证 BusinessStartKet + BusinessStartKetRedeem。
 *
 * 运行:
 *   npx tsx scripts/verifyBusinessStartKetStackOnScan.ts
 *   npx tsx scripts/verifyBusinessStartKetStackOnScan.ts BusinessStartKetRedeem
 *
 * 读取 deployments/conet-BusinessStartKet.json、conet-BusinessStartKetRedeem.json。
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder, getAddress } from "ethers";
import { fileURLToPath } from "url";
import {
  BASESCAN_COMPILER_VERSION,
  exportBasescanStandardJsonFromRoot,
} from "./basescanStandardJsonShared.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://scan.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://scan.conet.network").replace(/\/$/, "");
const CONET_RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const COMPILER_VERSION = `v${BASESCAN_COMPILER_VERSION}`;

type VerifyTarget = {
  key: string;
  address: string;
  rootSource: string;
  contractName: string;
  constructorTypes?: string[];
  constructorValues?: unknown[];
};

function loadTargets(): VerifyTarget[] {
  const ketPath = path.join(root, "deployments/conet-BusinessStartKet.json");
  const redeemPath = path.join(root, "deployments/conet-BusinessStartKetRedeem.json");
  if (!fs.existsSync(ketPath) || !fs.existsSync(redeemPath)) {
    throw new Error("缺少 conet-BusinessStartKet.json 或 conet-BusinessStartKetRedeem.json");
  }
  const ketData = JSON.parse(fs.readFileSync(ketPath, "utf-8")) as {
    contracts?: { BusinessStartKet?: { address?: string } };
    constructorArgs?: { uri?: string; name?: string; symbol?: string };
  };
  const redeemData = JSON.parse(fs.readFileSync(redeemPath, "utf-8")) as {
    contracts?: { BusinessStartKetRedeem?: { address?: string } };
    constructorArgs?: { ket?: string; buint?: string; initialRedeemAdmin?: string };
  };

  const ketAddr = ketData.contracts?.BusinessStartKet?.address;
  const redeemAddr = redeemData.contracts?.BusinessStartKetRedeem?.address;
  const ca = ketData.constructorArgs;
  const ra = redeemData.constructorArgs;
  if (!ketAddr || !redeemAddr || !ca?.uri || !ca?.name || !ca?.symbol) {
    throw new Error("部署 JSON 缺少 BusinessStartKet 地址或 constructorArgs");
  }
  if (!ra?.ket || !ra?.buint || !ra?.initialRedeemAdmin) {
    throw new Error("部署 JSON 缺少 BusinessStartKetRedeem constructorArgs");
  }

  return [
    {
      key: "BusinessStartKet",
      address: getAddress(ketAddr),
      rootSource: "project/src/b-unit/businessStartKet.sol",
      contractName: "project/src/b-unit/businessStartKet.sol:BusinessStartKet",
      constructorTypes: ["string", "string", "string"],
      constructorValues: [ca.uri, ca.name, ca.symbol],
    },
    {
      key: "BusinessStartKetRedeem",
      address: getAddress(redeemAddr),
      rootSource: "project/src/b-unit/BusinessStartKetRedeem.sol",
      contractName: "project/src/b-unit/BusinessStartKetRedeem.sol:BusinessStartKetRedeem",
      constructorTypes: ["address", "address", "address"],
      constructorValues: [getAddress(ra.ket), getAddress(ra.buint), getAddress(ra.initialRedeemAdmin)],
    },
  ];
}

function constructorArgsHex(target: VerifyTarget): string {
  if (!target.constructorTypes?.length) return "";
  return AbiCoder.defaultAbiCoder()
    .encode(target.constructorTypes, target.constructorValues ?? [])
    .slice(2);
}

async function rpcHasCode(address: string): Promise<boolean> {
  const res = await fetch(CONET_RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method: "eth_getCode", params: [address, "latest"], id: 1 }),
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

async function submitVerify(target: VerifyTarget, standardJson: string): Promise<void> {
  const ctor = constructorArgsHex(target);
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", target.contractName);
  form.set("autodetect_constructor_args", "false");
  form.set("constructor_args", ctor);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST ${target.key} @ ${target.address}`);
  console.log("  contract_name:", target.contractName);
  console.log("  standard-input bytes:", standardJson.length);

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string };
  try {
    out = JSON.parse(text) as { message?: string };
  } catch {
    console.error(text.slice(0, 2000));
    throw new Error(`非 JSON HTTP ${res.status}`);
  }
  console.log(" ", JSON.stringify(out));
  if (!res.ok || !/verification started|already verified/i.test(out.message ?? "")) {
    throw new Error(`${target.key} 提交失败: ${out.message ?? text.slice(0, 300)}`);
  }
}

async function waitVerified(address: string, label: string): Promise<boolean> {
  for (let i = 0; i < 40; i++) {
    if (await checkVerified(address)) {
      console.log(`  ✅ ${label}: ${BLOCKSCOUT_UI}/address/${address}#code`);
      return true;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.warn(`  ⚠️ ${label} 轮询超时`);
  return false;
}

async function verifyTarget(target: VerifyTarget): Promise<void> {
  if (!(await rpcHasCode(target.address))) {
    console.log(`⏭️ ${target.key} 链上无 code，跳过`);
    return;
  }
  if (await checkVerified(target.address)) {
    console.log(`⏭️ ${target.key} 已验证: ${BLOCKSCOUT_UI}/address/${target.address}#code`);
    return;
  }

  const { standardJson } = exportBasescanStandardJsonFromRoot(root, target.rootSource);
  await submitVerify(target, JSON.stringify(standardJson));
  await waitVerified(target.address, target.key);
}

async function main() {
  const only = (process.argv[2] || "").trim();
  let targets = loadTargets();
  if (only) {
    targets = targets.filter((t) => t.key === only || t.address.toLowerCase() === only.toLowerCase());
    if (!targets.length) throw new Error(`未找到目标: ${only}`);
  }

  console.log("CoNET Blockscout:", BLOCKSCOUT_UI);
  console.log("RPC:", CONET_RPC);

  for (const t of targets) {
    await verifyTarget(t);
  }
  console.log("\nDone.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
