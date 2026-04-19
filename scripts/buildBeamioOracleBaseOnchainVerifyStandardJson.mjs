#!/usr/bin/env node
/**
 * 生成 Base 主网 0xDa4…A9A2B BeamioOracle 的 BaseScan Standard JSON（与链上字节码一致）。
 *
 * 根因：当前 hardhat 默认 0.8.33 + viaIR + runs=0 + bytecodeHash:none，
 * 与部署时 0.8.30 + runs=200 + prague + ipfs 元数据 + 非 viaIR 不一致。
 *
 * 本脚本从 Sourcify full_match 拉取已验证的源码与 metadata.settings，拼出 standard-json 输入。
 *
 * 输出（两档）：
 * - basescan-standard-input.json：给 BaseScan **上传** — settings 与链上 metadata 一致，**不含** outputSelection
 *   （浏览器后端会自行注入；避免与表单选项叠加导致异常）。
 * - standard-input-devcheck.json：含 outputSelection，仅用于本地 `solc --standard-json` 核对字节码。
 * - basescan-standard-input-safe-paths.json：源路径改为 contracts/…（**不含逗号**），
 *   若 BaseScan 解析带逗号的 JSON key 失败可试此文件；链上 **完整** bytecode 与原版 metadata 不同，
 *   仅当浏览器按「去 metadata 后缀」比对时才会过（多数 Etherscan 系会 strip再比，可一试）。
 *
 * 用法:
 *   node scripts/buildBeamioOracleBaseOnchainVerifyStandardJson.mjs
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const CHAIN_ID = "8453";
const ADDRESS = "0xDa4AE8301262BdAaf1bb68EC91259E6C512A9A2B";
const SOURCIFY_FILES = `https://sourcify.dev/server/files/any/${CHAIN_ID}/${ADDRESS}`;

function sourceKeyFromSourcifyPath(fullPath) {
  const idx = fullPath.indexOf("/sources/");
  if (idx === -1) throw new Error(`Unexpected path (no /sources/): ${fullPath}`);
  return fullPath.slice(idx + "/sources/".length);
}

async function main() {
  const res = await fetch(SOURCIFY_FILES);
  if (!res.ok) {
    console.error("Sourcify fetch failed:", res.status, await res.text());
    process.exit(1);
  }
  const body = await res.json();
  if (body.status !== "full" || !Array.isArray(body.files)) {
    console.error("Unexpected Sourcify response:", body);
    process.exit(1);
  }

  const metaFile = body.files.find((f) => f.name === "metadata.json");
  if (!metaFile?.content) {
    console.error("metadata.json missing");
    process.exit(1);
  }
  const meta = JSON.parse(metaFile.content);
  const rawSettings = meta.settings;
  if (!rawSettings?.compilationTarget) {
    console.error("metadata.settings.compilationTarget missing");
    process.exit(1);
  }

  const { compilationTarget, ...restSettings } = rawSettings;
  const explorerSettings = {
    ...restSettings,
    viaIR: false,
  };

  const sources = {};
  for (const f of body.files) {
    if (f.name === "metadata.json" || f.name === "creator-tx-hash.txt") continue;
    if (!f.path || f.content === undefined) continue;
    const key = sourceKeyFromSourcifyPath(f.path);
    sources[key] = { content: f.content };
  }

  const sourcifyOracleKey = "settle on base,/AA/CCSA/BeamioOracle.sol";
  const sourcifyCurrencyKey = "settle on base,/AA/CCSA/BeamioCurrency.sol";
  if (!sources[sourcifyOracleKey] || !sources[sourcifyCurrencyKey]) {
    console.error("Missing expected Sourcify source keys");
    process.exit(1);
  }

  const safePathSources = {
    "contracts/BeamioOracle.sol": sources[sourcifyOracleKey],
    "contracts/BeamioCurrency.sol": sources[sourcifyCurrencyKey],
    "@openzeppelin/contracts/access/Ownable.sol": sources["@openzeppelin/contracts/access/Ownable.sol"],
    "@openzeppelin/contracts/utils/Context.sol": sources["@openzeppelin/contracts/utils/Context.sol"],
  };

  const deploymentsDir = path.join(__dirname, "../deployments");
  const outExplorer = path.join(deploymentsDir, "base-BeamioOracle-chain0xDa4-basescan-standard-input.json");
  const outDev = path.join(deploymentsDir, "base-BeamioOracle-chain0xDa4-standard-input-devcheck.json");
  const outSafe = path.join(deploymentsDir, "base-BeamioOracle-chain0xDa4-basescan-standard-input-safe-paths.json");

  const inputExplorer = {
    language: "Solidity",
    sources,
    settings: explorerSettings,
  };
  fs.writeFileSync(outExplorer, JSON.stringify(inputExplorer, null, 2), "utf-8");

  const inputDev = {
    language: "Solidity",
    sources,
    settings: {
      ...explorerSettings,
      outputSelection: {
        "*": {
          "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "metadata"],
        },
      },
    },
  };
  fs.writeFileSync(outDev, JSON.stringify(inputDev, null, 2), "utf-8");

  const inputSafe = {
    language: "Solidity",
    sources: safePathSources,
    settings: explorerSettings,
  };
  fs.writeFileSync(outSafe, JSON.stringify(inputSafe, null, 2), "utf-8");

  const targets = Object.entries(compilationTarget);
  console.log("Explorer上传:", outExplorer);
  console.log("本地 solc 核对:", outDev);
  console.log("逗号路径备用:", outSafe);
  console.log("Compiler:", meta.compiler?.version);
  console.log("Compilation target(s):", targets.map(([k, v]) => `${k}:${v}`).join(", "));
  console.log(
    "Settings:",
    JSON.stringify({
      optimizer: explorerSettings.optimizer,
      evmVersion: explorerSettings.evmVersion,
      viaIR: explorerSettings.viaIR,
      metadata: explorerSettings.metadata,
    })
  );
  console.log("");
  console.log("BaseScan：Verification method 选「Solidity (Standard Json-Input)」。");
  console.log("【关键】Compiler 必须选 v0.8.30+commit.73712a01，不要0.8.33（与仓库 Hardhat 默认不同，选错必 err_code_2）。");
  console.log("Contract name 先试: BeamioOracle（仅类名）；失败再试带路径全名。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
