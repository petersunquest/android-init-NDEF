/**
 * Blockscout v2 Standard JSON 验证 epoch_mining_info（mining_info.sol）。
 *
 * 前置: npm run compile && npx hardhat run scripts/deployConetEpochMiningInfoToCoet.ts --network conet
 *
 * 运行: npx tsx scripts/verifyConetEpochMiningInfoStandardJson.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");
const EXPLORER = "https://mainnet.conet.network";
const SOURCE_KEY = "project/src/b-unit/mining_info.sol";
const DEPLOYMENT_KEY = "epoch_mining_info";

function resolveAddress(): string {
  const fromEnv = process.env.EPOCH_MINING_INFO_ADDRESS?.trim();
  if (fromEnv) return fromEnv;
  const dep = path.join(root, "deployments", `conet-${DEPLOYMENT_KEY}.json`);
  if (fs.existsSync(dep)) {
    const j = JSON.parse(fs.readFileSync(dep, "utf-8")) as { address?: string };
    if (j.address) return j.address;
  }
  const addrJson = path.join(root, "deployments", "conet-addresses.json");
  if (fs.existsSync(addrJson)) {
    const j = JSON.parse(fs.readFileSync(addrJson, "utf-8")) as Record<string, string>;
    if (j.EpochMiningInfo) return j.EpochMiningInfo;
  }
  throw new Error("无法解析 EpochMiningInfo 地址");
}

function loadStandardInput(): { json: string; compilerVersion: string } {
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
        sources: bi.input.sources,
      };
      const v = bi.solcLongVersion ?? "0.8.33+commit.64118f21";
      return { json: JSON.stringify(inputObj), compilerVersion: v.startsWith("v") ? v : `v${v}` };
    } catch {
      /* skip */
    }
  }
  throw new Error(`未找到含 ${SOURCE_KEY} 的 build-info，请先 npm run compile`);
}

async function main() {
  const address = resolveAddress();
  const { json, compilerVersion } = loadStandardInput();

  const url = `${EXPLORER}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
  const blob = new Blob([json], { type: "application/json" });
  const form = new FormData();
  form.set("compiler_version", compilerVersion);
  form.set("contract_name", "epoch_mining_info");
  form.set("autodetect_constructor_args", "true");
  form.set("license_type", "mit");
  form.append("files[0]", blob, "standard-input.json");

  console.log("--- epoch_mining_info", address, "---");
  console.log("POST", url);
  console.log("compiler_version:", compilerVersion);

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string };
  try {
    out = JSON.parse(text) as { message?: string };
  } catch {
    console.error(text.slice(0, 2000));
    throw new Error(`非 JSON HTTP ${res.status}`);
  }
  console.log("HTTP", res.status, out.message ?? text.slice(0, 500));
  if (!res.ok) throw new Error(`验证失败: ${out.message ?? res.status}`);
  console.log("\n✅ epoch_mining_info 验证请求已提交");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
