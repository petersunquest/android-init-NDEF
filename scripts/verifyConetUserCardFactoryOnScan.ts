/**
 * 在 CoNET Blockscout (scan.conet.network) 验证 UserCard Factory 栈。
 *
 * 运行: npx tsx scripts/verifyConetUserCardFactoryOnScan.ts
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";
import {
  BASESCAN_COMPILER_VERSION,
  exportBasescanStandardJsonFromRoot,
} from "./basescanStandardJsonShared.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://scan.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://scan.conet.network").replace(/\/$/, "");
const COMPILER = `v${BASESCAN_COMPILER_VERSION}`;

type Target = {
  label: string;
  address: string;
  contractName: string;
  rootSource: string;
  constructorTypes?: string[];
  constructorValues?: unknown[];
  libraryLinks?: Record<string, Record<string, string>>;
};

function loadDeploy(): {
  executeLib: string;
  factory: string;
  usdc: string;
  redeemModule: string;
  quoteHelper: string;
  deployer: string;
  aaFactory: string;
  owner: string;
} {
  const f = JSON.parse(fs.readFileSync(path.join(root, "deployments/conet-UserCardFactory.json"), "utf-8"));
  const c = f.contracts.beamioUserCardFactoryPaymaster;
  return {
    executeLib: f.contracts.beamioUserCardFactoryExecuteLib.address,
    factory: c.address,
    usdc: c.usdc,
    redeemModule: c.redeemModule,
    quoteHelper: c.quoteHelper,
    deployer: c.deployer,
    aaFactory: c.aaFactory,
    owner: c.owner,
  };
}

function buildTargets(): Target[] {
  const d = loadDeploy();
  const libLinks = {
    "project/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol": {
      BeamioUserCardFactoryExecuteLib: d.executeLib,
    },
  };

  return [
    {
      label: "BeamioUserCardFactoryExecuteLib",
      address: d.executeLib,
      contractName: "BeamioUserCardFactoryExecuteLib",
      rootSource: "project/src/BeamioUserCard/BeamioUserCardFactoryExecuteLib.sol",
    },
    {
      label: "BeamioUserCardFactoryPaymasterV07",
      address: d.factory,
      contractName: "project/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol:BeamioUserCardFactoryPaymasterV07",
      rootSource: "project/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol",
      libraryLinks: libLinks,
      constructorTypes: ["address", "address", "address", "address", "address", "address"],
      constructorValues: [d.usdc, d.redeemModule, d.quoteHelper, d.deployer, d.aaFactory, d.owner],
    },
  ];
}

async function checkVerified(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (!res.ok) return false;
  const data = (await res.json()) as { is_verified?: boolean; source_code?: string | null };
  return Boolean(data.is_verified || data.source_code);
}

async function submit(target: Target): Promise<void> {
  const { standardJson } = exportBasescanStandardJsonFromRoot(root, target.rootSource);
  if (target.libraryLinks) {
    standardJson.settings.libraries = target.libraryLinks;
  }
  const json = JSON.stringify(standardJson);
  const ctor =
    target.constructorTypes?.length
      ? AbiCoder.defaultAbiCoder()
          .encode(target.constructorTypes, target.constructorValues ?? [])
          .slice(2)
      : "";

  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${target.address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER);
  form.set("contract_name", target.contractName);
  form.set("autodetect_constructor_args", ctor ? "false" : "true");
  if (ctor) form.set("constructor_args", ctor);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([json], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST ${target.label} @ ${target.address}`);
  const res = await fetch(url, { method: "POST", body: form });
  const data = (await res.json().catch(() => ({}))) as { message?: string };
  console.log(" ", JSON.stringify(data));
  if (!res.ok || !/verification started|already verified/i.test(data.message ?? "")) {
    throw new Error(`${target.label} 提交失败: ${data.message ?? res.status}`);
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

async function main() {
  console.log("CoNET UserCard Factory Blockscout verification");
  console.log("API:", BLOCKSCOUT_API);

  for (const t of buildTargets()) {
    if (await checkVerified(t.address)) {
      console.log(`⏭️ ${t.label} 已验证`);
      continue;
    }
    await submit(t);
    await waitVerified(t.address, t.label);
  }
  console.log("\n✅ UserCard Factory 验证流程完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
