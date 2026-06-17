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
/** 新链 Blockscout UI；旧 mainnet.conet.network 已弃用 */
const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://scan.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://scan.conet.network").replace(/\/$/, "");
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
  const exported = path.join(root, "deployments", "conet-epoch_mining_info-standard-input.json");
  if (fs.existsSync(exported)) {
    const input = fs.readFileSync(exported, "utf-8");
    const biPath = path.join(root, "artifacts", "build-info");
    const files = fs.readdirSync(biPath).filter((f) => f.endsWith(".json") && !f.includes(".output."));
    for (const f of files) {
      try {
        const bi = JSON.parse(fs.readFileSync(path.join(biPath, f), "utf-8")) as { solcLongVersion?: string };
        const v = bi.solcLongVersion ?? "0.8.33+commit.64118f21";
        return { json: input, compilerVersion: v.startsWith("v") ? v : `v${v}` };
      } catch {
        /* skip */
      }
    }
    return { json: input, compilerVersion: "v0.8.33+commit.64118f21" };
  }
  throw new Error(
    "未找到 deployments/conet-epoch_mining_info-standard-input.json；请先 node scripts/exportConetEpochMiningInfoStandardJson.mjs"
  );
}

async function main() {
  const address = resolveAddress();
  const { json, compilerVersion } = loadStandardInput();

  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${address}/verification/via/standard-input`;
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
  if (!res.ok && !/verification started|already verified/i.test(out.message ?? "")) {
    throw new Error(`验证失败: ${out.message ?? res.status}`);
  }
  console.log("\n✅ epoch_mining_info 验证请求已提交");
  console.log("查看:", `${BLOCKSCOUT_UI}/address/${address}#code`);

  for (let i = 0; i < 40; i++) {
    const check = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
    if (check.ok) {
      const data = (await check.json()) as { is_verified?: boolean; source_code?: string | null };
      if (data.is_verified || data.source_code) {
        console.log("✅ 已验证:", `${BLOCKSCOUT_UI}/address/${address}#code`);
        return;
      }
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.warn("⚠️ 轮询超时，请稍后在 Explorer 刷新 #code 页");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
