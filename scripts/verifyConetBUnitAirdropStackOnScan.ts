/**
 * CoNET Blockscout (mainnet.conet.network) 验证 BUnitAirdrop + BuintRedeemAirdrop。
 *
 * 守则: .cursor/rules/conet-mainnet-blockscout-verify.mdc
 *
 * 提交前:
 *   npm run compile
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BUnitAirdrop --full
 *   node scripts/exportStandardJsonFromBuildInfo.mjs BuintRedeemAirdrop --full
 *   node scripts/exportConetBUnitAirdropStackVerifyBuildinfo.mjs
 *
 * 运行:
 *   CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyConetBUnitAirdropStackOnScan.ts
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(
  /\/$/,
  "",
);
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");
const CONET_RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
/** 链上 bytecode 尾 `000823` → 0.8.35 */
const COMPILER_VERSION = process.env.CONET_SOLC_VERSION || "v0.8.35+commit.47b9dedd";

type Target = {
  label: string;
  address: string;
  contractNames: string[];
  verifyJson: string;
  constructorArgsHex: string;
};

function loadTargets(): Target[] {
  const airdropDeploy = JSON.parse(
    fs.readFileSync(path.join(root, "deployments/conet-BUintAirdrop.json"), "utf-8"),
  );
  const redeemDeploy = JSON.parse(
    fs.readFileSync(path.join(root, "deployments/conet-BuintRedeemAirdrop.json"), "utf-8"),
  );

  const airdropAddr = airdropDeploy.contracts.BUnitAirdrop.address as string;
  const buintFromAirdrop = airdropDeploy.contracts.BUint.address as string;
  const airdropDeployer = airdropDeploy.deployer as string;

  const redeemAddr = redeemDeploy.contracts.BuintRedeemAirdrop.address as string;
  const buintFromRedeem = redeemDeploy.contracts.BuintRedeemAirdrop.buint as string;
  const redeemAdmin = redeemDeploy.initialRedeemAdmin as string;

  const coder = AbiCoder.defaultAbiCoder();
  const airdropArgs = coder.encode(["address", "address"], [buintFromAirdrop, airdropDeployer]).slice(2);
  const redeemArgs = coder.encode(["address", "address"], [buintFromRedeem, redeemAdmin]).slice(2);

  return [
    {
      label: "BUnitAirdrop",
      address: airdropAddr,
      contractNames: [
        "project/src/b-unit/BUnitAirdrop.sol:BUnitAirdrop",
        "BUnitAirdrop",
      ],
      verifyJson: "deployments/conet-BUnitAirdrop-verify-buildinfo.json",
      constructorArgsHex: airdropArgs,
    },
    {
      label: "BuintRedeemAirdrop",
      address: redeemAddr,
      contractNames: [
        "project/src/b-unit/BuintRedeemAirdrop.sol:BuintRedeemAirdrop",
        "BuintRedeemAirdrop",
      ],
      verifyJson: "deployments/conet-BuintRedeemAirdrop-verify-buildinfo.json",
      constructorArgsHex: redeemArgs,
    },
  ];
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
  const v2 = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (!v2.ok) return false;
  const data = (await v2.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string | null;
  };
  if (data.is_verified || data.is_partially_verified) return true;
  return typeof data.source_code === "string" && data.source_code.length > 10;
}

async function submitVerify(target: Target, standardJson: string, contractName: string): Promise<void> {
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", contractName);
  form.set("constructor_args", target.constructorArgsHex);
  form.set("autodetect_constructor_args", "false");
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST (v2) ${target.label} @ ${target.address}`);
  console.log("  contract_name:", contractName);
  console.log("  compiler:", COMPILER_VERSION);
  console.log("  standard-input bytes:", standardJson.length);
  console.log("  constructor_args:", target.constructorArgsHex.slice(0, 20) + "…");

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
    throw new Error(`${target.label} v2 提交失败: ${out.message ?? text.slice(0, 300)}`);
  }
}

async function waitVerified(address: string, label: string): Promise<boolean> {
  const pollMax = Math.max(30, Number(process.env.CONET_VERIFY_POLL_MAX || 90) || 90);
  for (let i = 0; i < pollMax; i++) {
    if (await checkVerified(address)) {
      console.log(`  ✅ ${label}: ${BLOCKSCOUT_UI}/address/${address}#code`);
      return true;
    }
    await new Promise((r) => setTimeout(r, 4000));
  }
  console.warn(`  ⚠️ ${label} 轮询超时（可能仍在编译）`);
  return false;
}

async function verifyTarget(target: Target): Promise<void> {
  if (!(await rpcHasCode(target.address))) {
    console.log(`⏭️ ${target.label} 链上无 code，跳过`);
    return;
  }
  if (await checkVerified(target.address)) {
    console.log(`⏭️ ${target.label} 已验证: ${BLOCKSCOUT_UI}/address/${target.address}#code`);
    return;
  }

  const jsonPath = path.join(root, target.verifyJson);
  if (!fs.existsSync(jsonPath)) {
    throw new Error(`缺少 ${target.verifyJson}，请先跑 exportConetBUnitAirdropStackVerifyBuildinfo.mjs`);
  }
  const standardJson = fs.readFileSync(jsonPath, "utf-8");

  let lastErr: Error | undefined;
  for (const name of target.contractNames) {
    try {
      await submitVerify(target, standardJson, name);
      const ok = await waitVerified(target.address, target.label);
      if (ok) return;
      lastErr = new Error(`轮询超时: ${target.label}`);
    } catch (e) {
      lastErr = e as Error;
      console.warn(`  retry with next contract_name: ${(e as Error).message}`);
    }
  }
  throw lastErr ?? new Error(`${target.label} 验证失败`);
}

async function main() {
  console.log("=".repeat(60));
  console.log("Verify BUnitAirdrop stack on", BLOCKSCOUT_UI);
  console.log("=".repeat(60));

  const targets = loadTargets();
  const only = (process.env.CONET_VERIFY_ONLY || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

  let failed = 0;
  for (const t of targets) {
    if (only.length && !only.includes(t.label) && !only.includes(t.address)) continue;
    try {
      await verifyTarget(t);
    } catch (e) {
      failed++;
      console.error(`❌ ${t.label}:`, (e as Error).message);
    }
  }

  if (failed) process.exit(1);
  console.log("\n✅ 全部验证完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
