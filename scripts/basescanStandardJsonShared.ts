/**
 * BaseScan Standard JSON 导出共享逻辑（对齐 exportBeamioUserCardBasescanStandardJson.ts）。
 * - 从当前文件系统递归收集 import 依赖（含 node_modules/@openzeppelin）
 * - settings 与 hardhat.config.ts 一致；不含 compilationTarget（BaseScan 报 Unknown key）
 */

import * as fs from "fs";
import * as path from "path";

export const BASESCAN_COMPILER_VERSION = "0.8.33+commit.64118f21";

export type SourceMap = Record<string, { content: string }>;

export function toPosix(p: string): string {
  return p.split(path.sep).join(path.posix.sep);
}

/** project/src/... 或 @openzeppelin/contracts/... */
export function toSourceKeyFromAbs(rootDir: string, absPath: string): string {
  const nodeModules = path.join(rootDir, "node_modules");
  const resolved = path.resolve(absPath);
  if (resolved.startsWith(nodeModules + path.sep)) {
    return toPosix(path.relative(nodeModules, resolved));
  }
  return `project/${toPosix(path.relative(rootDir, resolved))}`;
}

export function toAbsolutePath(rootDir: string, rootSource: string): string {
  if (!rootSource.startsWith("project/")) {
    throw new Error(`root 必须以 project/ 开头，收到: ${rootSource}`);
  }
  return path.resolve(rootDir, rootSource.slice("project/".length));
}

export function resolveImport(rootDir: string, absImporter: string, importPath: string): string {
  if (importPath.startsWith("./") || importPath.startsWith("../")) {
    return path.resolve(path.dirname(absImporter), importPath);
  }
  if (importPath.startsWith("@")) {
    const npmPath = path.join(rootDir, "node_modules", importPath);
    if (fs.existsSync(npmPath)) return npmPath;
  }
  const fromRoot = path.resolve(rootDir, importPath);
  if (fs.existsSync(fromRoot)) return fromRoot;
  throw new Error(`无法解析 import: ${importPath} (from ${absImporter})`);
}

export function collectSources(
  rootDir: string,
  absEntry: string,
  sources: SourceMap,
  visited = new Set<string>()
): Set<string> {
  const absPath = path.resolve(absEntry);
  if (visited.has(absPath)) return visited;
  if (!fs.existsSync(absPath)) {
    throw new Error(`源码不存在: ${absPath}`);
  }

  visited.add(absPath);
  const content = fs.readFileSync(absPath, "utf-8");
  sources[toSourceKeyFromAbs(rootDir, absPath)] = { content };

  const importRegex = /^\s*import\s+(?:[^'"]+from\s+)?["']([^"']+)["'];/gm;
  for (const match of content.matchAll(importRegex)) {
    collectSources(rootDir, resolveImport(rootDir, absPath, match[1]), sources, visited);
  }

  return visited;
}

export function buildBasescanStandardJsonSettings() {
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

export function exportBasescanStandardJsonFromRoot(rootDir: string, rootSource: string): {
  standardJson: { language: string; sources: SourceMap; settings: ReturnType<typeof buildBasescanStandardJsonSettings> };
  sourceCount: number;
  sourceKeys: string[];
} {
  const rootAbsPath = toAbsolutePath(rootDir, rootSource);
  const sources: SourceMap = {};
  const visited = collectSources(rootDir, rootAbsPath, sources);
  const sourceKeys = Array.from(visited)
    .map((abs) => toSourceKeyFromAbs(rootDir, abs))
    .sort();
  return {
    standardJson: {
      language: "Solidity",
      sources,
      settings: buildBasescanStandardJsonSettings(),
    },
    sourceCount: sourceKeys.length,
    sourceKeys,
  };
}
