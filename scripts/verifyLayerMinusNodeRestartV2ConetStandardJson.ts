/**
 * 使用 Solidity Standard JSON Input 在 CoNET Blockscout v2 上验证 LayerMinusNodeRestart_V2。
 *
 * 前置:
 *   npm run compile
 *   node scripts/exportLayerMinusNodeRestartV2ConetStandardJson.mjs   # 可选；本脚本也可直接从 build-info 生成
 *
 * 运行:
 *   npx tsx scripts/verifyLayerMinusNodeRestartV2ConetStandardJson.ts
 *
 * 环境变量:
 *   LAYERMINUS_RESTART_V2_ADDRESS — 覆盖默认（否则读 deployments/conet-LayerMinusNodeRestart_V2.json 或 conet-addresses.json）
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const EXPLORER = "https://mainnet.conet.network";
const SOURCE_KEY = "project/src/mainnet/LayerMinusNodeRestart_V2.sol";

function resolveAddress(): string {
  const env = process.env.LAYERMINUS_RESTART_V2_ADDRESS?.trim();
  if (env) return env;
  const depJson = path.join(root, "deployments", "conet-LayerMinusNodeRestart_V2.json");
  if (fs.existsSync(depJson)) {
    const j = JSON.parse(fs.readFileSync(depJson, "utf-8")) as { address?: string };
    if (j.address) return j.address;
  }
  const addrJson = path.join(root, "deployments", "conet-addresses.json");
  if (fs.existsSync(addrJson)) {
    const j = JSON.parse(fs.readFileSync(addrJson, "utf-8")) as { LayerMinusNodeRestart_V2?: string };
    if (j.LayerMinusNodeRestart_V2) return j.LayerMinusNodeRestart_V2;
  }
  throw new Error("无法解析合约地址：设置 LAYERMINUS_RESTART_V2_ADDRESS 或保留 deployments 记录");
}

function loadMinimalStandardInput(): { json: string; compilerVersion: string } {
  const exported = path.join(root, "deployments", "conet-LayerMinusNodeRestart_V2-standard-input.json");
  if (fs.existsSync(exported)) {
    const input = fs.readFileSync(exported, "utf-8");
    const biPath = path.join(root, "artifacts", "build-info");
    const files = fs.readdirSync(biPath).filter((f) => f.endsWith(".json") && !f.includes(".output."));
    for (const f of files) {
      try {
        const bi = JSON.parse(fs.readFileSync(path.join(biPath, f), "utf-8")) as {
          solcLongVersion?: string;
          input?: { sources?: Record<string, unknown> };
        };
        if (bi.input?.sources?.[SOURCE_KEY]) {
          const v = bi.solcLongVersion ?? "0.8.33+commit.64118f21";
          const cv = v.startsWith("v") ? v : `v${v}`;
          return { json: input, compilerVersion: cv };
        }
      } catch {
        /* skip */
      }
    }
    const cv = "v0.8.33+commit.64118f21";
    return { json: input, compilerVersion: cv };
  }

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
  throw new Error(
    "无法构建 standard JSON：请先 npm run compile，或运行 exportLayerMinusNodeRestartV2ConetStandardJson.mjs",
  );
}

async function main() {
  const address = resolveAddress();
  const { json, compilerVersion } = loadMinimalStandardInput();

  const url = `${EXPLORER}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
  const blob = new Blob([json], { type: "application/json" });
  const form = new FormData();
  form.set("compiler_version", compilerVersion);
  form.set("contract_name", "LayerMinusNodeRestart_V2");
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
      process.exitCode = 1;
    }
  }
  console.log("\n可在浏览器查看: ", `${EXPLORER}/address/${address}#code`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
