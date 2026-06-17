/**
 * GuardianNodesInfoV6 在 CoNET Blockscout v2 上的最小 Standard JSON 验证。
 *
 * 前置: npm run compile
 *
 * 运行:
 *   npx tsx scripts/verifyGuardianNodesInfoV6ConetStandardJson.ts
 *
 * 环境变量:
 *   GUARDIAN_NODES_INFO_V6 — 覆盖合约地址（否则读 deployments/conet-GuardianNodesInfoV6.json）
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const EXPLORER = process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network";
const EXPLORER_API = (process.env.CONET_BLOCKSCOUT_API || `${EXPLORER}/api`).replace(/\/$/, "");
const SOURCE_KEY = "project/src/b-unit/GuardianNodesInfoV6.sol";

function resolveAddress(): string {
  const env = process.env.GUARDIAN_NODES_INFO_V6?.trim();
  if (env) return env;
  const dep = path.join(root, "deployments", "conet-GuardianNodesInfoV6.json");
  if (fs.existsSync(dep)) {
    const j = JSON.parse(fs.readFileSync(dep, "utf-8")) as {
      GuardianNodesInfoV6?: string;
      contracts?: { GuardianNodesInfoV6?: { address?: string } };
    };
    const fromContracts = j.contracts?.GuardianNodesInfoV6?.address;
    if (fromContracts) return fromContracts;
    if (j.GuardianNodesInfoV6) return j.GuardianNodesInfoV6;
  }
  const addrJson = path.join(root, "deployments", "conet-addresses.json");
  if (fs.existsSync(addrJson)) {
    const j = JSON.parse(fs.readFileSync(addrJson, "utf-8")) as { GuardianNodesInfoV6?: string };
    if (j.GuardianNodesInfoV6) return j.GuardianNodesInfoV6;
  }
  throw new Error("无法解析地址：设置 GUARDIAN_NODES_INFO_V6 或保留 deployments 记录");
}

function loadMinimalStandardInput(): { json: string; compilerVersion: string } {
  const biPath = path.join(root, "artifacts", "build-info");
  const files = fs.readdirSync(biPath).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  for (const f of files) {
    const p = path.join(biPath, f);
    try {
      const bi = JSON.parse(fs.readFileSync(p, "utf-8")) as {
        input: { language: string; settings: unknown; sources: Record<string, { content?: string }> };
        solcLongVersion: string;
      };
      if (!bi.input?.sources?.[SOURCE_KEY]) continue;
      const inputObj = {
        language: bi.input.language,
        settings: bi.input.settings,
        sources: { [SOURCE_KEY]: bi.input.sources[SOURCE_KEY] },
      };
      const v = bi.solcLongVersion ?? "0.8.33+commit.64118f21";
      const cv = v.startsWith("v") ? v : `v${v}`;
      return { json: JSON.stringify(inputObj), compilerVersion: cv };
    } catch {
      /* skip */
    }
  }
  throw new Error("无法构建 standard JSON：请先 npm run compile");
}

async function checkVerified(address: string, expectName: string): Promise<boolean> {
  const res = await fetch(`${EXPLORER_API}/v2/smart-contracts/${address}`);
  if (!res.ok) return false;
  const data = (await res.json()) as { is_verified?: boolean; name?: string };
  return Boolean(data.is_verified && data.name === expectName);
}

async function waitVerified(address: string, label: string, expectName: string, attempts = 40): Promise<boolean> {
  for (let i = 0; i < attempts; i++) {
    if (await checkVerified(address, expectName)) {
      console.log(`✅ ${label} 已验证: ${EXPLORER}/address/${address}#code`);
      return true;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.warn(`⚠️ ${label} 验证轮询超时，请稍后在 Blockscout 查看`);
  return false;
}

async function main() {
  const address = resolveAddress();
  const expectName = "GuardianNodesInfoV6";
  if (await checkVerified(address, expectName)) {
    console.log(`⏭️ GuardianNodesInfoV6 已验证: ${EXPLORER}/address/${address}#code`);
    return;
  }

  const { json, compilerVersion } = loadMinimalStandardInput();
  const url = `${EXPLORER_API}/v2/smart-contracts/${address}/verification/via/standard-input`;
  const blob = new Blob([json], { type: "application/json" });
  const form = new FormData();
  form.set("compiler_version", compilerVersion);
  form.set("contract_name", "project/src/b-unit/GuardianNodesInfoV6.sol:GuardianNodesInfoV6");
  form.set("autodetect_constructor_args", "true");
  form.set("constructor_args", "");
  form.set("license_type", "mit");
  form.append("files[0]", blob, "standard-input.json");

  console.log("POST", url);
  console.log("compiler_version:", compilerVersion);
  console.log("standard-input bytes:", json.length);

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string };
  try {
    out = JSON.parse(text) as { message?: string };
  } catch {
    console.error(text.slice(0, 2000));
    throw new Error(`非 JSON 响应 HTTP ${res.status}`);
  }
  console.log(JSON.stringify(out, null, 2));
  if (!res.ok || !/verification started|already verified/i.test(out.message ?? "")) {
    if (/fail|error/i.test(out.message ?? "") && !/already/i.test(text)) {
      throw new Error(out.message ?? text.slice(0, 500));
    }
  }
  await waitVerified(address, "GuardianNodesInfoV6", expectName);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
