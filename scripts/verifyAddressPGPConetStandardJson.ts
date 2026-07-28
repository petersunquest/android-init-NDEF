/**
 * AddressPGP 在 CoNET Blockscout v2 上的最小 Standard JSON 验证（规避 Hardhat verify 全量 input 413）。
 *
 * 前置: npm run compile
 *
 * 运行:
 *   npx tsx scripts/verifyAddressPGPConetStandardJson.ts
 *
 * 环境变量:
 *   ADDRESS_PGP — 覆盖合约地址（否则读 deployments/conet-AddressPGP.json）
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const EXPLORER = "https://mainnet.conet.network";
const ROOT_SOURCE = "project/src/mainnet/AddressPGP.sol";

function resolveAddress(): string {
  const env = process.env.ADDRESS_PGP?.trim();
  if (env) return env;
  const dep = path.join(root, "deployments", "conet-AddressPGP.json");
  if (fs.existsSync(dep)) {
    const j = JSON.parse(fs.readFileSync(dep, "utf-8")) as { AddressPGP?: string };
    if (j.AddressPGP) return j.AddressPGP;
  }
  throw new Error("无法解析地址：设置 ADDRESS_PGP 或保留 deployments/conet-AddressPGP.json");
}

function stripCommentsForImports(src: string): string {
  return src
    .replace(/\/\/[^\n]*/g, "")
    .replace(/\/\*[\s\S]*?\*\//g, "");
}

function extractImportPaths(content: string): string[] {
  const cleaned = stripCommentsForImports(content);
  const paths: string[] = [];
  const fromRe = /from\s+["']([^"']+)["']/g;
  const directRe = /import\s+["']([^"']+)["']\s*;/g;
  let m: RegExpExecArray | null;
  while ((m = fromRe.exec(cleaned))) paths.push(m[1]);
  while ((m = directRe.exec(cleaned))) paths.push(m[1]);
  return [...new Set(paths)];
}

function resolveImport(currentKey: string, imp: string): string {
  if (imp.startsWith("project/")) return path.posix.normalize(imp);
  if (!imp.startsWith(".")) {
    throw new Error(`非相对 import 需手工处理: ${imp} (from ${currentKey})`);
  }
  const dir = path.posix.dirname(currentKey);
  return path.posix.normalize(path.posix.join(dir, imp));
}

function loadBuildInfoWithRoot(): {
  input: { language: string; settings: unknown; sources: Record<string, { content?: string }> };
  solcLongVersion: string;
} {
  const biPath = path.join(root, "artifacts", "build-info");
  const files = fs.readdirSync(biPath).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  for (const f of files) {
    const p = path.join(biPath, f);
    try {
      const bi = JSON.parse(fs.readFileSync(p, "utf-8")) as {
        input?: { language: string; settings: unknown; sources: Record<string, { content?: string }> };
        solcLongVersion?: string;
      };
      if (bi.input?.sources?.[ROOT_SOURCE]) {
        return {
          input: bi.input as { language: string; settings: unknown; sources: Record<string, { content?: string }> },
          solcLongVersion: bi.solcLongVersion ?? "0.8.33+commit.64118f21",
        };
      }
    } catch {
      /* skip */
    }
  }
  throw new Error("未找到含 AddressPGP 的 build-info，请先 npm run compile");
}

function minimalSourcesFrom(
  fullSources: Record<string, { content?: string }>,
): Record<string, { content: string }> {
  const minimal: Record<string, { content: string }> = {};
  const queue: string[] = [ROOT_SOURCE];
  const seen = new Set<string>();

  while (queue.length) {
    const key = queue.pop()!;
    if (seen.has(key)) continue;
    seen.add(key);
    const entry = fullSources[key];
    const content = entry?.content;
    if (typeof content !== "string") {
      throw new Error(`缺少源码: ${key}`);
    }
    minimal[key] = { content };
    for (const imp of extractImportPaths(content)) {
      const resolved = resolveImport(key, imp);
      if (!fullSources[resolved]) {
        throw new Error(`import 无法映射到 build-info: ${resolved} (自 ${key} import ${imp})`);
      }
      if (!seen.has(resolved)) queue.push(resolved);
    }
  }
  return minimal;
}

function loadMinimalStandardInput(): { json: string; compilerVersion: string } {
  const { input, solcLongVersion } = loadBuildInfoWithRoot();
  const sources = minimalSourcesFrom(input.sources);
  const inputObj = {
    language: input.language,
    settings: input.settings,
    sources,
  };
  const cv = solcLongVersion.startsWith("v") ? solcLongVersion : `v${solcLongVersion}`;
  return { json: JSON.stringify(inputObj), compilerVersion: cv };
}

async function main() {
  const address = resolveAddress();
  const { json, compilerVersion } = loadMinimalStandardInput();

  const url = `${EXPLORER}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
  const blob = new Blob([json], { type: "application/json" });
  const form = new FormData();
  form.set("compiler_version", compilerVersion);
  form.set("contract_name", "AddressPGP");
  form.set("autodetect_constructor_args", "true");
  form.set("constructor_args", "");
  form.set("license_type", "mit");
  form.append("files[0]", blob, "standard-input.json");

  console.log("POST", url);
  console.log("compiler_version:", compilerVersion);
  console.log("standard-input bytes:", json.length);
  console.log("source files:", Object.keys(JSON.parse(json).sources as object).length);

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
