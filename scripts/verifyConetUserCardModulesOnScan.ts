/**
 * 在 CoNET Blockscout (scan.conet.network) 验证 UserCard 模块栈。
 *
 * 运行:
 *   npx tsx scripts/verifyConetUserCardModulesOnScan.ts
 *   npx tsx scripts/verifyConetUserCardModulesOnScan.ts AdminStatsQueryModule
 *
 * 环境变量:
 *   CONET_BLOCKSCOUT_API — 默认 https://scan.conet.network/api
 *   CONET_RPC_URL — 默认 https://publicrpc.conet.network
 *   CONET_VERIFY_ONLY — 仅验证指定 exportKey 或地址
 */

import * as fs from "fs";
import * as path from "path";
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
  exportKey: string;
  address: string;
  contractNames: string[];
  rootSource: string;
  libraryLinks?: Record<string, Record<string, string>>;
};

function loadModules(): Record<string, string> {
  const modulesPath = path.join(root, "deployments/conet-UserCardModules.json");
  const data = JSON.parse(fs.readFileSync(modulesPath, "utf-8")) as {
    modules: Record<string, string>;
  };
  return data.modules;
}

function loadLibAddresses(): {
  referrerLib: string;
  transferLib: string;
  moduleRouterLib: string;
} {
  const addrPath = path.join(root, "deployments/conet-addresses.json");
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, string>;
  return {
    referrerLib: data.beamioUserCardReferrerLib,
    transferLib: data.beamioUserCardTransferLib,
    moduleRouterLib: data.beamioUserCardModuleRouterLib,
  };
}

function buildTargets(): VerifyTarget[] {
  const m = loadModules();
  const libs = loadLibAddresses();

  return [
    {
      exportKey: "RedeemModule",
      address: m.redeemModule,
      rootSource: "project/src/BeamioUserCard/RedeemModule.sol",
      contractNames: [
        "project/src/BeamioUserCard/RedeemModule.sol:BeamioUserCardRedeemModuleVNext",
        "BeamioUserCardRedeemModuleVNext",
      ],
    },
    {
      exportKey: "IssuedNftModule",
      address: m.issuedNftModule,
      rootSource: "project/src/BeamioUserCard/IssuedNftModule.sol",
      contractNames: [
        "project/src/BeamioUserCard/IssuedNftModule.sol:BeamioUserCardIssuedNftModuleV1",
        "BeamioUserCardIssuedNftModuleV1",
      ],
    },
    {
      exportKey: "FaucetModule",
      address: m.faucetModule,
      rootSource: "project/src/BeamioUserCard/FaucetModule.sol",
      contractNames: [
        "project/src/BeamioUserCard/FaucetModule.sol:BeamioUserCardFaucetModuleV1",
        "BeamioUserCardFaucetModuleV1",
      ],
    },
    {
      exportKey: "GovernanceModule",
      address: m.governanceModule,
      rootSource: "project/src/BeamioUserCard/GovernanceModule.sol",
      contractNames: [
        "project/src/BeamioUserCard/GovernanceModule.sol:BeamioUserCardGovernanceModuleV1",
        "BeamioUserCardGovernanceModuleV1",
      ],
    },
    {
      exportKey: "MembershipStatsModule",
      address: m.membershipStatsModule,
      rootSource: "project/src/BeamioUserCard/MembershipStatsModule.sol",
      contractNames: [
        "project/src/BeamioUserCard/MembershipStatsModule.sol:BeamioUserCardMembershipStatsModuleV1",
        "BeamioUserCardMembershipStatsModuleV1",
      ],
    },
    {
      exportKey: "AdminStatsQueryModule",
      address: m.adminStatsQueryModule,
      rootSource: "project/src/BeamioUserCard/AdminStatsQueryModule.sol",
      contractNames: [
        "project/src/BeamioUserCard/AdminStatsQueryModule.sol:BeamioUserCardAdminStatsQueryModuleV1",
        "BeamioUserCardAdminStatsQueryModuleV1",
      ],
    },
    {
      exportKey: "ChargeRewardModule",
      address: m.chargeRewardModule,
      rootSource: "project/src/BeamioUserCard/ChargeRewardModule.sol",
      contractNames: [
        "project/src/BeamioUserCard/ChargeRewardModule.sol:BeamioUserCardChargeRewardModuleV1",
        "BeamioUserCardChargeRewardModuleV1",
      ],
      libraryLinks: {
        "project/src/BeamioUserCard/ChargeRewardModule.sol": {
          BeamioUserCardReferrerLib: libs.referrerLib,
          BeamioUserCardTransferLib: libs.transferLib,
        },
      },
    },
    {
      exportKey: "ModuleRouterLib",
      address: libs.moduleRouterLib,
      rootSource: "project/src/BeamioUserCard/BeamioUserCardModuleRouterLib.sol",
      contractNames: [
        "project/src/BeamioUserCard/BeamioUserCardModuleRouterLib.sol:BeamioUserCardModuleRouterLib",
        "BeamioUserCardModuleRouterLib",
      ],
    },
  ];
}

function loadStandardJson(target: VerifyTarget): string {
  const { standardJson } = exportBasescanStandardJsonFromRoot(root, target.rootSource);
  if (target.libraryLinks) {
    standardJson.settings.libraries = target.libraryLinks;
  }
  return JSON.stringify(standardJson);
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

async function submitVerify(target: VerifyTarget, standardJson: string, contractName: string): Promise<void> {
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", contractName);
  form.set("autodetect_constructor_args", "true");
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST ${target.exportKey} @ ${target.address}`);
  console.log("  contract_name:", contractName);

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
    throw new Error(`${target.exportKey} 提交失败: ${out.message ?? text.slice(0, 300)}`);
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
  console.warn(`  ⚠️ ${label} 轮询超时（可能仍在编译）`);
  return false;
}

async function verifyTarget(target: VerifyTarget): Promise<void> {
  if (!(await rpcHasCode(target.address))) {
    console.log(`⏭️ ${target.exportKey} 链上无 code，跳过`);
    return;
  }
  if (await checkVerified(target.address)) {
    console.log(`⏭️ ${target.exportKey} 已验证: ${BLOCKSCOUT_UI}/address/${target.address}#code`);
    return;
  }

  const standardJson = loadStandardJson(target);
  for (let i = 0; i < target.contractNames.length; i++) {
    const name = target.contractNames[i];
    try {
      await submitVerify(target, standardJson, name);
      await waitVerified(target.address, target.exportKey);
      return;
    } catch (e) {
      console.warn(`  contract_name=${name} 失败:`, (e as Error).message);
      if (i === target.contractNames.length - 1) throw e;
    }
  }
}

async function main() {
  const only = (process.env.CONET_VERIFY_ONLY || process.argv[2] || "").trim();
  let targets = buildTargets();
  if (only) {
    targets = targets.filter(
      (t) => t.exportKey === only || t.address.toLowerCase() === only.toLowerCase(),
    );
  }
  if (!targets.length) throw new Error(`未知目标: ${only}`);

  console.log("CoNET UserCard Modules Blockscout verification");
  console.log("API:", BLOCKSCOUT_API);
  console.log("RPC:", CONET_RPC);

  for (const t of targets) {
    await verifyTarget(t);
  }
  console.log("\n✅ UserCard 模块验证流程完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
