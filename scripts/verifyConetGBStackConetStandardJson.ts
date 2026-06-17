/**
 * Blockscout v2 Standard JSON 验证 CoNET GB 栈（ConetGB1155 / ConetGB_total / ConetGB_userTotal）。
 *
 * 前置: npm run compile && npx hardhat run scripts/deployConetGBStackToCoet.ts --network conet
 *
 * 运行:
 *   npx tsx scripts/verifyConetGBStackConetStandardJson.ts
 *   npx tsx scripts/verifyConetGBStackConetStandardJson.ts ConetGB1155
 *
 * 环境变量: CONET_GB_VERIFY_ONLY=ConetGB1155|ConetGB_total|ConetGB_userTotal
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { AbiCoder, getAddress } from "ethers";
import { GB_INITIAL_ADMIN } from "./gbDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");
const EXPLORER = "https://mainnet.conet.network";

type Target = {
  deploymentKey: string;
  contractName: string;
  sourceKey: string;
  addressEnv?: string;
};

const TARGETS: Target[] = [
  {
    deploymentKey: "ConetGB1155",
    contractName: "ConetGB1155",
    sourceKey: "project/src/b-unit/GB.sol",
    addressEnv: "CONET_GB1155_ADDRESS",
  },
  {
    deploymentKey: "ConetGB_total",
    contractName: "ConetGB_total",
    sourceKey: "project/src/b-unit/gbTotal.sol",
    addressEnv: "CONET_GB_TOTAL_ADDRESS",
  },
  {
    deploymentKey: "ConetGB_userTotal",
    contractName: "ConetGB_userTotal",
    sourceKey: "project/src/b-unit/gbUserTotal.sol",
    addressEnv: "CONET_GB_USER_TOTAL_ADDRESS",
  },
];

function resolveAddress(key: string, envName?: string): string {
  const fromEnv = envName ? process.env[envName]?.trim() : "";
  if (fromEnv) return fromEnv;
  const dep = path.join(root, "deployments", `conet-${key}.json`);
  if (fs.existsSync(dep)) {
    const j = JSON.parse(fs.readFileSync(dep, "utf-8")) as { address?: string };
    if (j.address) return j.address;
  }
  const addrJson = path.join(root, "deployments", "conet-addresses.json");
  if (fs.existsSync(addrJson)) {
    const j = JSON.parse(fs.readFileSync(addrJson, "utf-8")) as Record<string, string>;
    if (j[key]) return j[key];
  }
  throw new Error(`无法解析 ${key} 地址`);
}

function loadStandardInput(sourceKey: string): { json: string; compilerVersion: string } {
  const biPath = path.join(root, "artifacts", "build-info");
  const files = fs.readdirSync(biPath).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  for (const f of files) {
    const p = path.join(biPath, f);
    try {
      const bi = JSON.parse(fs.readFileSync(p, "utf-8")) as {
        input: { language: string; settings: unknown; sources: Record<string, { content?: string }> };
        solcLongVersion: string;
      };
      if (!bi.input?.sources?.[sourceKey]) continue;
      const inputObj = {
        language: bi.input.language,
        settings: bi.input.settings,
        sources: bi.input.sources,
      };
      const v = bi.solcLongVersion ?? "0.8.33+commit.64118f21";
      return { json: JSON.stringify(inputObj), compilerVersion: v.startsWith("v") ? v : `v${v}` };
    } catch {
      /* skip */
    }
  }
  throw new Error(`未找到含 ${sourceKey} 的 build-info，请先 npm run compile`);
}

function loadConstructorArgsHex(deploymentKey: string): string {
  const dep = path.join(root, "deployments", `conet-${deploymentKey}.json`);
  if (!fs.existsSync(dep)) return "";
  const j = JSON.parse(fs.readFileSync(dep, "utf-8")) as {
    constructorArgs?: (string | number)[];
  };
  if (!j.constructorArgs?.length) return "";
  const coder = AbiCoder.defaultAbiCoder();
  if (deploymentKey === "ConetGB1155") {
    const [st, hid, admin] = j.constructorArgs;
    const adminAddr = admin
      ? getAddress(String(admin))
      : GB_INITIAL_ADMIN;
    return coder
      .encode(["uint64", "uint64", "address"], [BigInt(st), BigInt(hid), adminAddr])
      .slice(2);
  }
  if (deploymentKey === "ConetGB_total" || deploymentKey === "ConetGB_userTotal") {
    const [gb] = j.constructorArgs;
    return coder.encode(["address"], [getAddress(String(gb))]).slice(2);
  }
  return "";
}

async function verifyOne(t: Target): Promise<void> {
  const address = resolveAddress(t.deploymentKey, t.addressEnv);
  const { json, compilerVersion } = loadStandardInput(t.sourceKey);
  const constructorArgs = loadConstructorArgsHex(t.deploymentKey);

  const url = `${EXPLORER}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
  const blob = new Blob([json], { type: "application/json" });
  const form = new FormData();
  form.set("compiler_version", compilerVersion);
  form.set("contract_name", t.contractName);
  form.set("autodetect_constructor_args", constructorArgs ? "false" : "true");
  form.set("constructor_args", constructorArgs);
  form.set("license_type", "mit");
  form.append("files[0]", blob, "standard-input.json");

  console.log("\n---", t.contractName, address, "---");
  console.log("POST", url);
  console.log("compiler_version:", compilerVersion);
  if (constructorArgs) console.log("constructor_args:", constructorArgs.slice(0, 40) + "...");

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string };
  try {
    out = JSON.parse(text) as { message?: string };
  } catch {
    console.error(text.slice(0, 2000));
    throw new Error(`${t.contractName}: 非 JSON HTTP ${res.status}`);
  }
  console.log("HTTP", res.status, out.message ?? text.slice(0, 500));
  if (!res.ok) throw new Error(`${t.contractName} 验证失败: ${out.message ?? res.status}`);
}

async function main() {
  const only = (process.env.CONET_GB_VERIFY_ONLY || process.argv[2] || "").trim();
  const list = only ? TARGETS.filter((t) => t.contractName === only || t.deploymentKey === only) : TARGETS;
  if (!list.length) throw new Error(`未知验证目标: ${only}`);

  for (const t of list) {
    await verifyOne(t);
  }
  console.log("\n✅ GB 栈验证请求已提交");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
