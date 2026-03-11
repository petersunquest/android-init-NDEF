/**
 * 从 Hardhat build-info 导出某个 Solidity 根文件的最小 Standard JSON Input。
 *
 * 用法:
 *   npx tsx scripts/exportMinimalStandardJson.ts \
 *     --root project/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol \
 *     --out deployments/base-UserCardFactory-standard-input.min.json
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const args = process.argv.slice(2);

function getArg(name: string): string {
  const idx = args.indexOf(name);
  if (idx === -1 || idx + 1 >= args.length) {
    throw new Error(`缺少参数 ${name}`);
  }
  return args[idx + 1];
}

function getBuildInfoPath(rootSource: string): string {
  const buildInfoDir = path.join(__dirname, "..", "artifacts", "build-info");
  const files = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  for (const file of files) {
    const full = path.join(buildInfoDir, file);
    const content = fs.readFileSync(full, "utf-8");
    if (content.includes(rootSource)) return full;
  }
  throw new Error(`未找到包含 ${rootSource} 的 build-info，请先运行 npm run compile`);
}

function normalizeImport(importPath: string, currentFile: string): string {
  if (importPath.startsWith("./") || importPath.startsWith("../")) {
    const currentDir = path.posix.dirname(currentFile);
    return path.posix.normalize(path.posix.join(currentDir, importPath));
  }
  return importPath;
}

function collectDeps(
  root: string,
  sources: Record<string, { content: string }>,
  visited = new Set<string>()
): Set<string> {
  if (visited.has(root)) return visited;
  if (!sources[root]) throw new Error(`Standard JSON sources 中找不到: ${root}`);
  visited.add(root);

  const content = sources[root].content;
  const importRegex = /^\s*import\s+(?:[^'"]+from\s+)?["']([^"']+)["'];/gm;
  for (const match of content.matchAll(importRegex)) {
    const next = normalizeImport(match[1], root);
    if (sources[next]) {
      collectDeps(next, sources, visited);
    }
  }
  return visited;
}

function main() {
  const rootSource = getArg("--root");
  const outPath = path.resolve(process.cwd(), getArg("--out"));

  const buildInfoPath = getBuildInfoPath(rootSource);
  const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
  const fullInput = buildInfo.input as {
    language: string;
    sources: Record<string, { content: string }>;
    settings: Record<string, unknown>;
  };

  const deps = Array.from(collectDeps(rootSource, fullInput.sources)).sort();
  const minimalSources: Record<string, { content: string }> = {};
  for (const key of deps) {
    minimalSources[key] = fullInput.sources[key];
  }

  const minimalInput = {
    language: fullInput.language,
    sources: minimalSources,
    settings: fullInput.settings,
  };

  fs.writeFileSync(outPath, JSON.stringify(minimalInput, null, 2), "utf-8");
  console.log(`已导出 ${deps.length} 个源码文件到: ${outPath}`);
  console.log(`build-info: ${path.basename(buildInfoPath)}`);
}

main();
