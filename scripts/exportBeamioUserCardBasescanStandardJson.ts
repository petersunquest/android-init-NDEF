/**
 * 导出 BeamioUserCard 的 Standard JSON Input，用于 BaseScan 合约验证。
 *
 * 运行:
 *   npx tsx scripts/exportBeamioUserCardBasescanStandardJson.ts
 *
 * 输出:
 *   deployments/base-BeamioUserCard-basescan-standard-input.json  (完整版)
 *   deployments/base-BeamioUserCard-basescan-minimal.json         (最小版，仅 BeamioUserCard 依赖)
 *   deployments/base-BeamioUserCard-basescan-verify-meta.txt       (验证说明)
 *
 * err_code_2 (bytecode 不匹配) 排查:
 *   1. Constructor Arguments 必须与链上部署时完全一致
 *   2. 优先尝试 minimal 版本（27 个源文件），若仍失败再试完整版
 *   3. 或使用 Hardhat: npx hardhat verify --network base <地址> "uri" 4 "1000000" "owner" "gateway"
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BUILD_INFO_DIR = path.join(__dirname, "..", "artifacts", "build-info");
const OUT_DIR = path.join(__dirname, "..", "deployments");

const USER_CARD_SOURCE = "project/src/BeamioUserCard/BeamioUserCard.sol";
const FACTORY_SOURCE = "project/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol";

function getBuildInfoPath(): string {
  if (!fs.existsSync(BUILD_INFO_DIR)) {
    throw new Error("artifacts/build-info 不存在，请先运行: npx hardhat compile");
  }
  const files = fs.readdirSync(BUILD_INFO_DIR).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  for (const file of files) {
    const fullPath = path.join(BUILD_INFO_DIR, file);
    const content = fs.readFileSync(fullPath, "utf-8");
    if (content.includes(USER_CARD_SOURCE) && content.includes(FACTORY_SOURCE)) {
      return fullPath;
    }
  }
  throw new Error("未找到包含 BeamioUserCard 的 build-info，请先运行: npx hardhat compile");
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
  if (!sources[root]) return visited;
  visited.add(root);
  const content = sources[root].content;
  const importRegex = /^\s*import\s+(?:[^'"]+from\s+)?["']([^"']+)["'];/gm;
  for (const match of content.matchAll(importRegex)) {
    const next = normalizeImport(match[1], root);
    if (sources[next]) collectDeps(next, sources, visited);
  }
  return visited;
}

function main() {
  const buildInfoPath = getBuildInfoPath();
  const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
  const fullInput = buildInfo.input as {
    language: string;
    sources: Record<string, { content: string }>;
    settings: Record<string, unknown>;
  };
  const compilerVersion = buildInfo.solcLongVersion || "0.8.33+commit.64118f21";

  if (!fs.existsSync(OUT_DIR)) {
    fs.mkdirSync(OUT_DIR, { recursive: true });
  }

  // 1. 完整版（与 build-info 一致，用于精确匹配）
  const fullStandardJson = {
    language: fullInput.language,
    sources: fullInput.sources,
    settings: fullInput.settings,
  };
  const fullPath = path.join(OUT_DIR, "base-BeamioUserCard-basescan-standard-input.json");
  fs.writeFileSync(fullPath, JSON.stringify(fullStandardJson, null, 2), "utf-8");

  // 2. 最小版（仅 BeamioUserCard 依赖，部分场景可避免 err_code_2）
  const deps = Array.from(collectDeps(USER_CARD_SOURCE, fullInput.sources)).sort();
  const minimalSources: Record<string, { content: string }> = {};
  for (const key of deps) {
    minimalSources[key] = fullInput.sources[key];
  }
  const minimalStandardJson = {
    language: fullInput.language,
    sources: minimalSources,
    settings: fullInput.settings,
  };
  const minimalPath = path.join(OUT_DIR, "base-BeamioUserCard-basescan-minimal.json");
  fs.writeFileSync(minimalPath, JSON.stringify(minimalStandardJson, null, 2), "utf-8");

  const metaLines = [
    `BeamioUserCard BaseScan 合约验证`,
    `================================`,
    ``,
    `Compiler Version: ${compilerVersion}`,
    `Optimization: Enabled, Runs: 1`,
    `viaIR: true, evmVersion: ${(fullInput.settings as { evmVersion?: string }).evmVersion ?? "cancun"}`,
    ``,
    `Contract Name: ${USER_CARD_SOURCE}:BeamioUserCard`,
    ``,
    `Standard JSON 文件:`,
    `  - ${path.basename(fullPath)} (完整版，与部署时编译一致，推荐)`,
    `  - ${path.basename(minimalPath)} (${deps.length} 个源，可作备选)`,
    ``,
    `err_code_2 排查:`,
    `  1. Constructor Arguments 必须与 createCard 部署时完全一致 (uri, currency, price, owner, gateway)`,
    `  2. owner 为 createCard 时的 cardOwner (AA 会 resolve 为 EOA)`,
    `  3. 或: npx hardhat verify --network base <地址> "uri" 4 "1000000" "0xOwner" "0xGateway"`,
    ``,
    `Constructor 编码 (Node):`,
    `  require("ethers").AbiCoder.defaultAbiCoder().encode(`,
    `    ["string","uint8","uint256","address","address"],`,
    `    ["https://beamio.app/api/metadata/0x", 4, "1000000", "0x...", "0x46E8a69f7296deF53e33844bb00D92309ab46233"]`,
    `  ).slice(2)`,
  ];
  const metaPath = path.join(OUT_DIR, "base-BeamioUserCard-basescan-verify-meta.txt");
  fs.writeFileSync(metaPath, metaLines.join("\n") + "\n", "utf-8");

  console.log("已导出 BeamioUserCard Standard JSON (BaseScan):");
  console.log("  完整版:", fullPath, `(${(fs.statSync(fullPath).size / 1024).toFixed(1)} KB)`);
  console.log("  最小版:", minimalPath, `(${(fs.statSync(minimalPath).size / 1024).toFixed(1)} KB, ${deps.length} 源)`);
  console.log("  说明:", metaPath);
  console.log("\nContract Name:", `${USER_CARD_SOURCE}:BeamioUserCard`);
}

main();
