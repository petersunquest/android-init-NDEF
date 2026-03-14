/**
 * 从当前文件系统递归导出某个 Solidity 根文件的最小 Standard JSON Input。
 *
 * 说明:
 * - 不依赖 artifacts/build-info，避免旧编译缓存导致导出过期源码
 * - 直接按当前 workspace 文件内容递归收集 import 依赖
 * - 输出 settings 与 hardhat.config.ts 的 Solidity 配置保持一致
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
const ROOT_DIR = path.join(__dirname, "..");

const args = process.argv.slice(2);

function getArg(name: string): string {
  const idx = args.indexOf(name);
  if (idx === -1 || idx + 1 >= args.length) {
    throw new Error(`缺少参数 ${name}`);
  }
  return args[idx + 1];
}

function toPosix(p: string): string {
  return p.split(path.sep).join(path.posix.sep);
}

function toSourceKey(absPath: string): string {
  return `project/${toPosix(path.relative(ROOT_DIR, absPath))}`;
}

function toAbsolutePath(rootSource: string): string {
  if (!rootSource.startsWith("project/")) {
    throw new Error(`--root 必须以 project/ 开头，收到: ${rootSource}`);
  }
  return path.resolve(ROOT_DIR, rootSource.slice("project/".length));
}

function resolveImport(absImporter: string, importPath: string): string {
  if (importPath.startsWith("./") || importPath.startsWith("../")) {
    return path.resolve(path.dirname(absImporter), importPath);
  }
  const fromRoot = path.resolve(ROOT_DIR, importPath);
  if (fs.existsSync(fromRoot)) return fromRoot;
  throw new Error(`无法解析 import: ${importPath} (from ${absImporter})`);
}

function collectSources(
  absEntry: string,
  sources: Record<string, { content: string }>,
  visited = new Set<string>()
): Set<string> {
  const absPath = path.resolve(absEntry);
  if (visited.has(absPath)) return visited;
  if (!fs.existsSync(absPath)) {
    throw new Error(`源码不存在: ${absPath}`);
  }

  visited.add(absPath);
  const content = fs.readFileSync(absPath, "utf-8");
  sources[toSourceKey(absPath)] = { content };

  const importRegex = /^\s*import\s+(?:[^'"]+from\s+)?["']([^"']+)["'];/gm;
  for (const match of content.matchAll(importRegex)) {
    collectSources(resolveImport(absPath, match[1]), sources, visited);
  }

  return visited;
}

function buildSettings() {
  return {
    metadata: {
      bytecodeHash: "none",
    },
    debug: {
      revertStrings: "strip",
    },
    optimizer: {
      enabled: true,
      runs: 0,
    },
    viaIR: true,
    evmVersion: "cancun",
    remappings: [],
    outputSelection: {
      "*": {
        "": ["ast"],
        "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
      },
    },
  };
}

function main() {
  const rootSource = getArg("--root");
  const outPath = path.resolve(process.cwd(), getArg("--out"));
  const rootAbsPath = toAbsolutePath(rootSource);
  const minimalSources: Record<string, { content: string }> = {};
  const deps = Array.from(collectSources(rootAbsPath, minimalSources))
    .map((absPath) => toSourceKey(absPath))
    .sort();

  const minimalInput = {
    language: "Solidity",
    sources: minimalSources,
    settings: buildSettings(),
  };

  fs.writeFileSync(outPath, JSON.stringify(minimalInput, null, 2), "utf-8");
  console.log(`已导出 ${deps.length} 个源码文件到: ${outPath}`);
  console.log(`source root: ${rootSource}`);
}

main();
