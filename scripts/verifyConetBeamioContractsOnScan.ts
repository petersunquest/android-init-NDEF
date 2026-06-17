/**
 * CoNET Blockscout 验证 Beamio AA Factory、Container Module、Nick CREATE2 factory。
 *
 * 运行:
 *   npx tsx scripts/verifyConetBeamioContractsOnScan.ts
 *   npx tsx scripts/verifyConetBeamioContractsOnScan.ts BeamioFactoryPaymasterV07
 *
 * 环境变量:
 *   CONET_BLOCKSCOUT_API — 默认 https://scan.conet.network/api
 *   CONET_RPC_URL — 默认 https://publicrpc.conet.network
 *   CONET_VERIFY_ONLY — 仅验证指定 exportKey
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";
import {
  BEAMIO_AA_FACTORY_ADMIN,
  BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT,
  BEAMIO_AA_FACTORY_PREDICTED,
} from "./aaDeployConstants.js";
import { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";
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
  contractName: string;
  /** project/src/... root for collectSources; omit when using formJsonPath */
  rootSource?: string;
  formJsonPath?: string;
  constructorTypes?: string[];
  constructorValues?: unknown[];
  libraryLinks?: Record<string, Record<string, string>>;
};

function loadContainerStack(): Record<string, string> {
  const p = path.join(root, "deployments/conet-ContainerModuleStack.json");
  const j = JSON.parse(fs.readFileSync(p, "utf-8")) as {
    contracts: Record<string, { address: string }>;
  };
  return Object.fromEntries(Object.entries(j.contracts).map(([k, v]) => [k, v.address]));
}

function buildTargets(): VerifyTarget[] {
  const stack = loadContainerStack();
  const lib1 = stack.BeamioContainerExtLibV07;
  const lib2 = stack.BeamioContainerExtLib2V07;
  const module = stack.BeamioContainerModuleV07;

  return [
    {
      exportKey: "BeamioContainerModuleExternalLibV07",
      address: lib1,
      contractName: "BeamioContainerModuleExternalLibV07",
      rootSource: "project/src/BeamioAccount/BeamioContainerModuleExternalLibV07.sol",
    },
    {
      exportKey: "BeamioContainerModuleExternalLib2V07",
      address: lib2,
      contractName: "BeamioContainerModuleExternalLib2V07",
      rootSource: "project/src/BeamioAccount/BeamioContainerModuleExternalLib2V07.sol",
    },
    {
      exportKey: "BeamioContainerModuleV07",
      address: module,
      contractName: "BeamioContainerModuleV07",
      rootSource: "project/src/BeamioAccount/BeamioContainerModuleV07.sol",
      libraryLinks: {
        "project/src/BeamioAccount/BeamioContainerModuleExternalLibV07.sol": {
          BeamioContainerModuleExternalLibV07: lib1,
        },
        "project/src/BeamioAccount/BeamioContainerModuleExternalLib2V07.sol": {
          BeamioContainerModuleExternalLib2V07: lib2,
        },
      },
    },
    {
      exportKey: "BeamioFactoryPaymasterV07",
      address: BEAMIO_AA_FACTORY_PREDICTED,
      contractName: "project/src/BeamioAccount/BeamioFactoryPaymasterV07.sol:BeamioFactoryPaymasterV07",
      formJsonPath: "deployments/base-BeamioFactoryPaymasterV07-standard-input-FULL-FORM.json",
      constructorTypes: ["uint256", "address"],
      constructorValues: [BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT, BEAMIO_AA_FACTORY_ADMIN],
    },
    {
      exportKey: "NickCreate2Factory",
      address: NICK_CREATE2_FACTORY,
      contractName: "Proxy",
      formJsonPath: "deployments/conet-NickCreate2Factory-standard-input-yul.json",
    },
  ];
}

function loadStandardJson(target: VerifyTarget): string {
  if (target.formJsonPath) {
    const p = path.join(root, target.formJsonPath);
    if (!fs.existsSync(p)) throw new Error(`缺少 ${target.formJsonPath}`);
    return fs.readFileSync(p, "utf-8");
  }
  if (!target.rootSource) throw new Error(`${target.exportKey}: 无 rootSource / formJsonPath`);
  const { standardJson } = exportBasescanStandardJsonFromRoot(root, target.rootSource);
  if (target.libraryLinks) {
    standardJson.settings.libraries = target.libraryLinks;
  }
  return JSON.stringify(standardJson);
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
  const ctor = constructorArgsHex(target);
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", contractName);
  form.set("autodetect_constructor_args", ctor ? "false" : "true");
  if (ctor) form.set("constructor_args", ctor);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST ${target.exportKey} @ ${target.address}`);
  console.log("  contract_name:", contractName);
  if (ctor) console.log("  constructor_args:", ctor);

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
  console.warn(`  ⚠️ ${label} 轮询超时`);
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
  const names =
    target.exportKey === "BeamioFactoryPaymasterV07"
      ? [target.contractName, "BeamioFactoryPaymasterV07"]
      : target.exportKey === "NickCreate2Factory"
        ? ["Proxy", "runtime", "Create2Deployer"]
        : [target.contractName];

  for (const name of names) {
    try {
      await submitVerify(target, standardJson, name);
      await waitVerified(target.address, target.exportKey);
      return;
    } catch (e) {
      console.warn(`  contract_name=${name} 失败:`, (e as Error).message);
      if (name === names[names.length - 1]) throw e;
    }
  }
}

async function main() {
  const only = (process.env.CONET_VERIFY_ONLY || process.argv[2] || "").trim();
  let targets = buildTargets();
  if (only) {
    targets = targets.filter((t) => t.exportKey === only || t.address.toLowerCase() === only.toLowerCase());
  }
  if (!targets.length) throw new Error(`未知目标: ${only}`);

  console.log("CoNET Blockscout verification");
  console.log("API:", BLOCKSCOUT_API);
  console.log("RPC:", CONET_RPC);

  for (const t of targets) {
    await verifyTarget(t);
  }
  console.log("\n✅ 验证流程完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
