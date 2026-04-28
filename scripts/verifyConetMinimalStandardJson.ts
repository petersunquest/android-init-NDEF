import * as fs from "fs";
import * as path from "path";
import { AbiCoder } from "ethers";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");
const EXPLORER = "https://mainnet.conet.network";

function req(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`缺少环境变量 ${name}`);
  }
  return value;
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

function loadBuildInfoWithRoot(rootSource: string): {
  input: { language: string; settings: Record<string, unknown>; sources: Record<string, { content?: string }> };
  solcLongVersion: string;
} {
  const biPath = path.join(root, "artifacts", "build-info");
  const files = fs.readdirSync(biPath).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  for (const f of files) {
    const p = path.join(biPath, f);
    try {
      const bi = JSON.parse(fs.readFileSync(p, "utf-8")) as {
        input?: { language: string; settings: Record<string, unknown>; sources: Record<string, { content?: string }> };
        solcLongVersion?: string;
      };
      if (bi.input?.sources?.[rootSource]) {
        return {
          input: bi.input,
          solcLongVersion: bi.solcLongVersion ?? "0.8.33+commit.64118f21",
        };
      }
    } catch {
      // ignore malformed build-info files
    }
  }
  throw new Error(`未找到含源码 ${rootSource} 的 build-info，请先编译`);
}

function minimalSourcesFrom(
  fullSources: Record<string, { content?: string }>,
  rootSource: string
): Record<string, { content: string }> {
  const minimal: Record<string, { content: string }> = {};
  const queue: string[] = [rootSource];
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

function readConstructorArgs(): { constructorArgs: string; autodetect: boolean } {
  const rawHex = process.env.VERIFY_CONSTRUCTOR_ARGS?.trim();
  if (rawHex) {
    return {
      constructorArgs: rawHex.startsWith("0x") ? rawHex.slice(2) : rawHex,
      autodetect: false,
    };
  }

  const typesJson = process.env.VERIFY_CONSTRUCTOR_TYPES_JSON?.trim();
  const valuesJson = process.env.VERIFY_CONSTRUCTOR_VALUES_JSON?.trim();
  if (typesJson && valuesJson) {
    const types = JSON.parse(typesJson) as string[];
    const values = JSON.parse(valuesJson) as unknown[];
    const encoded = AbiCoder.defaultAbiCoder().encode(types, values);
    return {
      constructorArgs: encoded.startsWith("0x") ? encoded.slice(2) : encoded,
      autodetect: false,
    };
  }

  return {
    constructorArgs: "",
    autodetect: process.env.VERIFY_AUTODETECT_ARGS === "true",
  };
}

function mergeLibraries(settings: Record<string, unknown>): Record<string, unknown> {
  const librariesJson = process.env.VERIFY_LIBRARIES_JSON?.trim();
  if (!librariesJson) return settings;
  const libraries = JSON.parse(librariesJson) as Record<string, Record<string, string>>;
  const next = { ...settings };
  next.libraries = {
    ...((settings.libraries as Record<string, Record<string, string>> | undefined) ?? {}),
    ...libraries,
  };
  return next;
}

async function main() {
  const address = req("VERIFY_ADDRESS");
  const rootSource = req("VERIFY_SOURCE_KEY");
  const contractName = req("VERIFY_CONTRACT_NAME");
  const licenseType = process.env.VERIFY_LICENSE_TYPE?.trim() || "mit";

  const { input, solcLongVersion } = loadBuildInfoWithRoot(rootSource);
  const sources = minimalSourcesFrom(input.sources, rootSource);
  const settings = mergeLibraries(input.settings);
  const { constructorArgs, autodetect } = readConstructorArgs();

  const inputObj = {
    language: input.language,
    settings,
    sources,
  };
  const json = JSON.stringify(inputObj);
  const compilerVersion = solcLongVersion.startsWith("v") ? solcLongVersion : `v${solcLongVersion}`;

  const url = `${EXPLORER}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", compilerVersion);
  form.set("contract_name", contractName);
  form.set("autodetect_constructor_args", autodetect ? "true" : "false");
  form.set("constructor_args", constructorArgs);
  form.set("license_type", licenseType);
  form.append("files[0]", new Blob([json], { type: "application/json" }), "standard-input.json");

  console.log("POST", url);
  console.log("contract_name:", contractName);
  console.log("compiler_version:", compilerVersion);
  console.log("source files:", Object.keys(sources).length);
  console.log("standard-input bytes:", json.length);

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string; errors?: unknown };
  try {
    out = JSON.parse(text) as { message?: string; errors?: unknown };
  } catch {
    console.error(text.slice(0, 2000));
    throw new Error(`非 JSON 响应 HTTP ${res.status}`);
  }

  console.log(JSON.stringify(out, null, 2));
  if (!res.ok || !/verification started|already verified/i.test(out.message ?? "")) {
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
