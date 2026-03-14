/**
 * 导出 BeamioUserCard 的 Standard JSON Input，用于 BaseScan 合约验证。
 *
 * 说明：
 * - 不再依赖 artifacts/build-info，避免误用旧编译缓存
 * - 直接从当前文件系统递归收集 BeamioUserCard 真实依赖
 * - 生成的 sources 会与当前工作区源码保持一致
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.join(__dirname, "..");
const SRC_DIR = path.join(ROOT_DIR, "src");
const OUT_DIR = path.join(ROOT_DIR, "deployments");

const COMPILER_VERSION = "0.8.33+commit.64118f21";
const USER_CARD_ABS = path.join(SRC_DIR, "BeamioUserCard", "BeamioUserCard.sol");
const USER_CARD_SOURCE_KEY = "project/src/BeamioUserCard/BeamioUserCard.sol";

type SourceMap = Record<string, { content: string }>;

function toPosix(p: string): string {
  return p.split(path.sep).join(path.posix.sep);
}

function toSourceKey(absPath: string): string {
  const rel = toPosix(path.relative(ROOT_DIR, absPath));
  return `project/${rel}`;
}

function resolveImport(absImporter: string, importPath: string): string {
  if (importPath.startsWith("./") || importPath.startsWith("../")) {
    return path.resolve(path.dirname(absImporter), importPath);
  }
  const fromRoot = path.resolve(ROOT_DIR, importPath);
  if (fs.existsSync(fromRoot)) return fromRoot;
  throw new Error(`无法解析 import: ${importPath} (from ${absImporter})`);
}

function collectSources(absEntry: string, sources: SourceMap, visited = new Set<string>()): void {
  const absPath = path.resolve(absEntry);
  if (visited.has(absPath)) return;
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
  if (!fs.existsSync(OUT_DIR)) {
    fs.mkdirSync(OUT_DIR, { recursive: true });
  }

  const sources: SourceMap = {};
  collectSources(USER_CARD_ABS, sources);
  const sourceCount = Object.keys(sources).length;

  const standardJson = {
    language: "Solidity",
    sources,
    settings: buildSettings(),
  };

  const fullPath = path.join(OUT_DIR, "base-BeamioUserCard-basescan-standard-input.json");
  const minimalPath = path.join(OUT_DIR, "base-BeamioUserCard-basescan-minimal.json");
  fs.writeFileSync(fullPath, JSON.stringify(standardJson, null, 2), "utf-8");
  fs.writeFileSync(minimalPath, JSON.stringify(standardJson, null, 2), "utf-8");

  const metaLines = [
    `BeamioUserCard BaseScan 合约验证`,
    `================================`,
    ``,
    `Compiler Version: ${COMPILER_VERSION}`,
    `Optimization: Enabled, Runs: 0`,
    `viaIR: true, evmVersion: cancun`,
    ``,
    `Contract Name: ${USER_CARD_SOURCE_KEY}:BeamioUserCard`,
    ``,
    `Standard JSON 文件:`,
    `  - ${path.basename(fullPath)} (${sourceCount} 个当前源码依赖，推荐)`,
    `  - ${path.basename(minimalPath)} (${sourceCount} 个当前源码依赖，内容相同，作为备份)`,
    ``,
    `重要：BaseScan 新版 STANDARD_JSON_INPUT 页面不会手动选择 Contract Name，`,
    `它会从上传 JSON 自动匹配；若失败，请先确认 Constructor Arguments ABI-encoded 未留空。`,
  ];
  const metaPath = path.join(OUT_DIR, "base-BeamioUserCard-basescan-verify-meta.txt");
  fs.writeFileSync(metaPath, metaLines.join("\n") + "\n", "utf-8");

  console.log("已导出 BeamioUserCard Standard JSON (BaseScan):");
  console.log("  标准版:", fullPath, `(${(fs.statSync(fullPath).size / 1024).toFixed(1)} KB, ${sourceCount} 源)`);
  console.log("  备份版:", minimalPath, `(${(fs.statSync(minimalPath).size / 1024).toFixed(1)} KB, ${sourceCount} 源)`);
  console.log("  说明:", metaPath);
  console.log("\nContract Name:", `${USER_CARD_SOURCE_KEY}:BeamioUserCard`);
}

main();
