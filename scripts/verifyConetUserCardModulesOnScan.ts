/**
 * 在 CoNET Blockscout (mainnet.conet.network) 验证 UserCard 模块栈。
 *
 * 守则: .cursor/rules/conet-mainnet-blockscout-verify.mdc
 *
 * 提交前须 regenerate 并本地 bytecode 预检:
 *   node scripts/exportConetUserCardModuleV2VerifyBuildinfo.mjs
 *
 * V2 模块默认使用 deployments/conet-*-verify-buildinfo.json（FULL build-info 递归剪枝），
 * 仅走 Blockscout v2 standard-input API（legacy 对 build-info 包常失败 — 勿 fallback）。
 *
 * 运行:
 *   npx tsx scripts/verifyConetUserCardModulesOnScan.ts
 *   CONET_VERIFY_POLL_MAX=180 CONET_VERIFY_ONLY=BeamioUserCardIssuedNftModuleV2 npx tsx scripts/verifyConetUserCardModulesOnScan.ts
 *
 * 环境变量:
 *   CONET_BLOCKSCOUT_API — 默认 https://mainnet.conet.network/api
 *   CONET_RPC_URL — 默认 https://publicrpc.conet.network
 *   CONET_VERIFY_ONLY — 仅验证指定 exportKey 或地址
 *   CONET_VERIFY_POLL_MAX — 轮询次数（默认 90，每次 4s；Blockscout 忙时用 180）
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  exportBasescanStandardJsonFromRoot,
} from "./basescanStandardJsonShared.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(
  /\/$/,
  "",
);
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");
const CONET_RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
/** CoNET 新部署模块（0.8.35）；历史模块可设 CONET_SOLC_VERSION=v0.8.33+commit.64118f21 */
const COMPILER_VERSION =
  process.env.CONET_SOLC_VERSION || "v0.8.35+commit.47b9dedd";

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
      exportKey: "BeamioUserCardIssuedNftModuleV2",
      address: m.issuedNftModule,
      rootSource: "project/src/BeamioUserCard/IssuedNftModuleV2.sol",
      contractNames: [
        "project/src/BeamioUserCard/IssuedNftModuleV2.sol:BeamioUserCardIssuedNftModuleV2",
        "BeamioUserCardIssuedNftModuleV2",
      ],
    },
    {
      exportKey: "BeamioUserCardChargeRewardModuleV2",
      address: m.chargeRewardModule,
      rootSource: "project/src/BeamioUserCard/ChargeRewardModuleV2.sol",
      contractNames: [
        "project/src/BeamioUserCard/ChargeRewardModuleV2.sol:BeamioUserCardChargeRewardModuleV2",
        "BeamioUserCardChargeRewardModuleV2",
      ],
      libraryLinks: {
        "project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol": {
          BeamioUserCardReferrerLib: libs.referrerLib,
        },
        "project/src/BeamioUserCard/BeamioUserCardTransferLib.sol": {
          BeamioUserCardTransferLib: libs.transferLib,
        },
      },
    },
    {
      exportKey: "BeamioUserCardAdminStatsQueryModuleV2",
      address: m.adminStatsQueryModule,
      rootSource: "project/src/BeamioUserCard/AdminStatsQueryModuleV2.sol",
      contractNames: [
        "project/src/BeamioUserCard/AdminStatsQueryModuleV2.sol:BeamioUserCardAdminStatsQueryModuleV2",
        "BeamioUserCardAdminStatsQueryModuleV2",
      ],
    },
    {
      exportKey: "BeamioUserCardAdminStatsQueryModuleV3",
      address: m.adminStatsQueryModule,
      rootSource: "project/src/BeamioUserCard/AdminStatsQueryModuleV3.sol",
      contractNames: [
        "project/src/BeamioUserCard/AdminStatsQueryModuleV3.sol:BeamioUserCardAdminStatsQueryModuleV3",
        "BeamioUserCardAdminStatsQueryModuleV3",
      ],
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
    {
      exportKey: "BeamioUserCardUpdateLib",
      address: loadUpdateLibAddress(),
      rootSource: "project/src/BeamioUserCard/BeamioUserCardUpdateLib.sol",
      contractNames: [
        "project/src/BeamioUserCard/BeamioUserCardUpdateLib.sol:BeamioUserCardUpdateLib",
        "BeamioUserCardUpdateLib",
      ],
      libraryLinks: {
        "project/src/BeamioUserCard/BeamioUserCardUpdateLib.sol": {
          BeamioUserCardReferrerLib: libs.referrerLib,
          BeamioUserCardTransferLib: libs.transferLib,
        },
      },
    },
  ];
}

function loadUpdateLibAddress(): string {
  const addrPath = path.join(root, "deployments/conet-addresses.json");
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, string>;
  return data.beamioUserCardUpdateLib;
}

/** V2 模块优先用 build-info 剪枝 JSON（与链上 bytecode 100% 匹配）；legacy verify 常失败，仅走 v2。 */
const V2_BUILDINFO_JSON: Record<string, string> = {
  BeamioUserCardIssuedNftModuleV2: "conet-IssuedNftModuleV2-verify-buildinfo.json",
  BeamioUserCardChargeRewardModuleV2: "conet-ChargeRewardModuleV2-verify-buildinfo.json",
  BeamioUserCardAdminStatsQueryModuleV2: "conet-AdminStatsQueryModuleV2-verify-buildinfo.json",
  BeamioUserCardAdminStatsQueryModuleV3: "conet-AdminStatsQueryModuleV3-verify-buildinfo.json",
};

function usesBuildInfoVerifyJson(exportKey: string): boolean {
  const file = V2_BUILDINFO_JSON[exportKey];
  if (!file) return false;
  return fs.existsSync(path.join(root, "deployments", file));
}

function fullJsonPathForTarget(exportKey: string): string | null {
  const buildInfoFile = V2_BUILDINFO_JSON[exportKey];
  if (buildInfoFile) {
    const buildInfoAbs = path.join(root, "deployments", buildInfoFile);
    if (fs.existsSync(buildInfoAbs)) return buildInfoAbs;
  }

  const map: Record<string, string> = {
    BeamioUserCardIssuedNftModuleV2: "conet-IssuedNftModuleV2-standard-input-FULL-FORM.json",
    BeamioUserCardChargeRewardModuleV2: "conet-ChargeRewardModuleV2-standard-input-FULL-FORM.json",
    BeamioUserCardAdminStatsQueryModuleV2: "conet-AdminStatsQueryModuleV2-standard-input-FULL-FORM.json",
    BeamioUserCardAdminStatsQueryModuleV3: "conet-AdminStatsQueryModuleV3-standard-input-FULL-FORM.json",
  };
  const file = map[exportKey];
  if (!file) return null;
  const abs = path.join(root, "deployments", file);
  if (fs.existsSync(abs)) return abs;
  const fallback: Record<string, string> = {
    BeamioUserCardIssuedNftModuleV2: "base-BeamioUserCardIssuedNftModuleV2-standard-input-FULL.json",
    BeamioUserCardChargeRewardModuleV2: "conet-BeamioUserCardChargeRewardModuleV2-standard-input-FULL-linked.json",
    BeamioUserCardAdminStatsQueryModuleV2: "base-BeamioUserCardAdminStatsQueryModuleV2-standard-input-FULL.json",
    BeamioUserCardAdminStatsQueryModuleV3: "base-BeamioUserCardAdminStatsQueryModuleV3-standard-input-FULL.json",
  };
  const fb = fallback[exportKey];
  if (!fb) return null;
  const fbAbs = path.join(root, "deployments", fb);
  return fs.existsSync(fbAbs) ? fbAbs : null;
}

function loadStandardJson(target: VerifyTarget): string {
  const fullPath = fullJsonPathForTarget(target.exportKey);
  if (fullPath) {
    if (usesBuildInfoVerifyJson(target.exportKey)) {
      console.log(`  using build-info verify JSON: ${path.basename(fullPath)}`);
    }
    return fs.readFileSync(fullPath, "utf-8");
  }
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
  const v2 = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (v2.ok) {
    const data = (await v2.json()) as {
      is_verified?: boolean;
      is_partially_verified?: boolean;
      source_code?: string | null;
    };
    if (data.is_verified || data.is_partially_verified) return true;
  }
  const legacy = await fetch(
    `${BLOCKSCOUT_API}?module=contract&action=getsourcecode&address=${address}`,
  );
  if (!legacy.ok) return false;
  const leg = (await legacy.json()) as { result?: Array<{ SourceCode?: string; ABI?: string; ContractName?: string }> };
  const row = leg.result?.[0];
  const src = row?.SourceCode ?? "";
  const abi = row?.ABI ?? "";
  const name = row?.ContractName ?? "";
  if (!name || name === "Contract source code not verified") return false;
  return src.length > 10 && abi.length > 10 && abi !== "Contract source code not verified";
}

async function submitVerifyLegacy(target: VerifyTarget, standardJson: string, contractName: string): Promise<void> {
  const body = new URLSearchParams();
  body.set("addressHash", target.address);
  body.set("contractaddress", target.address);
  body.set("contractname", contractName);
  body.set("compilerversion", COMPILER_VERSION);
  body.set("codeformat", "solidity-standard-json-input");
  body.set("sourceCode", standardJson);
  body.set("contractSourceCode", standardJson);
  body.set("constructorArguments", "");
  body.set("autodetectConstructorArguments", "true");

  console.log(`\nPOST (legacy) ${target.exportKey} @ ${target.address}`);
  console.log("  contract_name:", contractName);
  console.log("  standard-input bytes:", standardJson.length);

  const res = await fetch(`${BLOCKSCOUT_API}?module=contract&action=verifysourcecode`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const out = (await res.json()) as { status?: string; result?: string; message?: string };
  console.log(" ", JSON.stringify(out));
  const guid = out.result;
  if (out.status !== "1" || !guid) {
    throw new Error(`legacy 提交失败: ${out.message ?? out.result ?? "unknown"}`);
  }
  for (let i = 0; i < 45; i++) {
    await new Promise((r) => setTimeout(r, 4000));
    const c = await fetch(`${BLOCKSCOUT_API}?module=contract&action=checkverifystatus&guid=${guid}`);
    const ct = (await c.json()) as { result?: string };
    const msg = ct.result ?? "";
    if (/pass|verified|already/i.test(msg)) {
      console.log(`  ✅ legacy 已验证: ${BLOCKSCOUT_UI}/address/${target.address}#code`);
      return;
    }
    if (/fail|error/i.test(msg)) {
      throw new Error(`legacy 验证失败: ${msg}`);
    }
  }
  throw new Error(`legacy 验证轮询超时: ${target.address}`);
}

async function submitVerify(target: VerifyTarget, standardJson: string, contractName: string): Promise<void> {
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", contractName);
  form.set("autodetect_constructor_args", "true");
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST (v2) ${target.exportKey} @ ${target.address}`);
  console.log("  contract_name:", contractName);
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
    throw new Error(`${target.exportKey} v2 提交失败: ${out.message ?? text.slice(0, 300)}`);
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
  const preferFullPathName = usesBuildInfoVerifyJson(target.exportKey);
  const namesToTry = (
    preferFullPathName
      ? [target.contractNames[0], ...target.contractNames.slice(1)]
      : [...target.contractNames, target.contractNames[target.contractNames.length - 1]]
  ).filter((n, i, a) => a.indexOf(n) === i);

  for (const contractName of namesToTry) {
    try {
      await submitVerify(target, standardJson, contractName);
      if (await waitVerified(target.address, target.exportKey)) return;
      console.warn(`  v2 (${contractName}) 轮询未通过，尝试下一 contract_name…`);
    } catch (e) {
      console.warn(`  v2 (${contractName}) 失败: ${(e as Error).message}`);
    }
  }

  if (usesBuildInfoVerifyJson(target.exportKey)) {
    throw new Error(
      `${target.exportKey} v2 验证未完成；build-info JSON 与 legacy API 不兼容，勿用 legacy 重复提交`,
    );
  }

  const legacyName = target.contractNames[target.contractNames.length - 1];
  await submitVerifyLegacy(target, standardJson, legacyName);
  if (!(await checkVerified(target.address))) {
    throw new Error(`${target.exportKey} legacy 后仍未验证`);
  }
  console.log(`  ✅ ${target.exportKey}: ${BLOCKSCOUT_UI}/address/${target.address}#code`);
}

async function main() {
  const only = (process.env.CONET_VERIFY_ONLY || process.argv[2] || "").trim();
  let targets = buildTargets();
  if (only) {
    const keys = only.split(",").map((s) => s.trim()).filter(Boolean);
    targets = targets.filter(
      (t) =>
        keys.includes(t.exportKey) ||
        keys.some((k) => t.address.toLowerCase() === k.toLowerCase()),
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
