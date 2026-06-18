/**
 * 使用 Standard JSON Input 验证 BeamioBUnits (BUint) 和 BUnitAirdrop
 * 支持 via-IR，解决 flattened 方式验证失败问题
 *
 * 运行: npx tsx scripts/verifyBUintAirdropStandardJson.ts
 * 仅验证 BUnitAirdrop: npx tsx scripts/verifyBUintAirdropStandardJson.ts --airdrop-only
 * 同时尝试 Hardhat verify: 添加 --try-hardhat（Standard JSON 成功但 Explorer 仍未验证时可试）
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { BUINT_INITIAL_ADMIN } from "./bunitDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://scan.conet.network").replace(/\/$/, "");
const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || `${BLOCKSCOUT_UI}/api`).replace(/\/$/, "");
const COMPILER_VERSION = "v0.8.33+commit.64118f21";

// BUint 无依赖，仅需自身；constructor(initialAdmin)
const BUINT_SOURCES = ["project/src/b-unit/BUint.sol"];

type StandardJsonInput = {
  language: string;
  sources: Record<string, { content: string }>;
  settings: Record<string, unknown> & {
    compilationTarget?: unknown;
    libraries?: Record<string, unknown>;
    remappings?: string[];
  };
};

/**
 * Hardhat 3 的 build-info 会把 npm 依赖写成 `npm/@openzeppelin/contracts@5.4.0/...`
 * 并通过 remappings 解析 `@openzeppelin/...`。Blockscout 的 Standard JSON
 * 验证器不会回调文件系统，因此必须让 source key 与 import 字符串直接一致。
 */
function normalizeNpmSourceKeysForBlockscout(stdInput: StandardJsonInput): StandardJsonInput {
  const input = JSON.parse(JSON.stringify(stdInput)) as StandardJsonInput;
  const rawRemappings = Array.isArray(input.settings?.remappings) ? input.settings.remappings : [];
  const npmPrefixMap: Array<{ prefix: string; target: string }> = [];

  for (const r of rawRemappings) {
    const eq = r.indexOf("=");
    if (eq < 0) continue;
    const left = r.slice(0, eq);
    const target = r.slice(eq + 1);
    if (!target.startsWith("npm/")) continue;
    const colon = left.indexOf(":");
    const prefix = colon >= 0 ? left.slice(colon + 1) : left;
    npmPrefixMap.push({ prefix, target });
  }

  npmPrefixMap.sort((a, b) => b.target.length - a.target.length);

  const remapKey = (key: string) => {
    if (!key.startsWith("npm/")) return key;
    for (const { prefix, target } of npmPrefixMap) {
      if (key.startsWith(target)) return prefix + key.slice(target.length);
    }
    return key;
  };

  input.sources = Object.fromEntries(Object.entries(input.sources).map(([k, v]) => [remapKey(k), v]));

  if (input.settings?.libraries && typeof input.settings.libraries === "object") {
    input.settings.libraries = Object.fromEntries(
      Object.entries(input.settings.libraries).map(([k, v]) => [remapKey(k), v])
    );
  }

  if (input.settings) {
    input.settings.remappings = [];
    delete input.settings.compilationTarget;
  }

  return input;
}

function resolveImportSourceKey(fromKey: string, specifier: string): string {
  if (specifier.startsWith("./") || specifier.startsWith("../")) {
    return path.posix.normalize(path.posix.join(path.posix.dirname(fromKey), specifier));
  }
  return specifier;
}

function getRecursiveSourceKeys(fullInput: StandardJsonInput, entryKeys: string[]): string[] {
  const seen = new Set<string>();
  const stack = [...entryKeys];
  const importRegex = /^\s*import\s+(?:[^'"]+from\s+)?["']([^"']+)["'];/gm;

  while (stack.length > 0) {
    const key = stack.pop()!;
    if (seen.has(key)) continue;
    const source = fullInput.sources[key];
    if (!source) {
      throw new Error(`Standard JSON 缺少依赖源文件: ${key}`);
    }
    seen.add(key);

    for (const match of source.content.matchAll(importRegex)) {
      const importKey = resolveImportSourceKey(key, match[1]);
      if (!seen.has(importKey)) stack.push(importKey);
    }
  }

  return [...seen].sort();
}

// BUnitAirdrop：从入口文件递归收集完整依赖（含 OpenZeppelin npm 源）
function getBUnitAirdropSources(fullInput: StandardJsonInput): string[] {
  return getRecursiveSourceKeys(fullInput, ["project/src/b-unit/BUnitAirdrop.sol"]);
}

async function verifyViaStandardJson(
  address: string,
  contractName: string,
  sourceKeys: string[],
  fullInput: StandardJsonInput,
  constructorArgsHex: string
): Promise<{ ok: boolean; message: string }> {
  const minimalSources: Record<string, { content: string }> = {};
  for (const key of sourceKeys) {
    if (fullInput.sources[key]) {
      minimalSources[key] = fullInput.sources[key];
    }
  }

  const minimalInput = {
    language: fullInput.language,
    sources: minimalSources,
    settings: fullInput.settings,
  };

  const standardJson = JSON.stringify(minimalInput);
  console.log(`  Standard JSON 大小: ${standardJson.length} bytes`);
  console.log(`  contract_name: ${contractName}`);

  const v2Url = `${BLOCKSCOUT_API}/v2/smart-contracts/${address}/verification/via/standard-input`;
  const formData = new FormData();
  formData.append("compiler_version", COMPILER_VERSION);
  formData.append("contract_name", contractName);
  formData.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");
  formData.append("constructor_args", constructorArgsHex);
  formData.append("autodetect_constructor_args", "false");
  formData.append("license_type", "mit");

  const res = await fetch(v2Url, { method: "POST", body: formData });
  const data = (await res.json().catch(() => ({}))) as { status?: string; result?: string; message?: string };

  if (!res.ok) {
    console.error("  API 响应 status:", res.status, res.statusText);
    console.error("  API 响应 body:", JSON.stringify(data, null, 2));
  } else if (process.env.VERBOSE) {
    console.log("  API 响应:", JSON.stringify(data, null, 2));
  }

  const ok =
    res.ok &&
    (data.status === "1" ||
      (data.message?.toLowerCase().includes("verification started") ?? false) ||
      (data.message?.toLowerCase().includes("already verified") ?? false));

  return { ok, message: data.message || JSON.stringify(data) };
}

async function main() {
  const airdropOnly = process.argv.includes("--airdrop-only");

  const deployPath = path.join(__dirname, "../deployments/conet-BUintAirdrop.json");
  const deploy = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const buintAddr = deploy.contracts?.BUint?.address;
  const airdropAddr = deploy.contracts?.BUnitAirdrop?.address;
  const deployer = deploy.deployer;

  if (!buintAddr || !airdropAddr || !deployer) {
    throw new Error("部署文件缺少 BUint / BUnitAirdrop 地址或 deployer");
  }

  // 查找包含 BUint 的 build-info
  const buildInfoDir = path.join(__dirname, "../artifacts/build-info");
  const files = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json") && !f.includes(".output."));
  let buildInfoPath: string | null = null;
  for (const f of files) {
    const content = fs.readFileSync(path.join(buildInfoDir, f), "utf-8");
    if (content.includes("project/src/b-unit/BUint.sol")) {
      buildInfoPath = path.join(buildInfoDir, f);
      break;
    }
  }

  if (!buildInfoPath) {
    throw new Error("未找到包含 BUint 的 build-info，请先运行: npx hardhat compile");
  }

  const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf-8"));
  const fullInput = normalizeNpmSourceKeysForBlockscout(buildInfo.input as StandardJsonInput);

  console.log("=".repeat(60));
  console.log("验证 BUint 与 BUnitAirdrop (Standard JSON Input)");
  console.log("=".repeat(60));
  console.log("BUint:", buintAddr);
  console.log("BUnitAirdrop:", airdropAddr);
  console.log("build-info:", path.basename(buildInfoPath));
  console.log("viaIR:", (fullInput.settings as { viaIR?: boolean })?.viaIR);

  // 1. 验证 BeamioBUnits (--airdrop-only 时跳过)
  if (!airdropOnly) {
    console.log("\n[1] 验证 BeamioBUnits...");
    const { AbiCoder } = await import("ethers");
    const coder = AbiCoder.defaultAbiCoder();
    const buintCtorHex = coder.encode(["address"], [BUINT_INITIAL_ADMIN]);
    const buintCtorArgs = buintCtorHex.startsWith("0x") ? buintCtorHex.slice(2) : buintCtorHex;
    const r1 = await verifyViaStandardJson(
      buintAddr,
      "project/src/b-unit/BUint.sol:BeamioBUnits",
      BUINT_SOURCES,
      fullInput,
      buintCtorArgs
    );
    if (r1.ok) {
      console.log("  ✅ BeamioBUnits 验证成功");
    } else {
      console.error("  ❌ BeamioBUnits 验证失败:", r1.message);
      if (!r1.message.toLowerCase().includes("already verified")) process.exit(1);
    }
  }

  // 2. 验证 BUnitAirdrop
  const { AbiCoder } = await import("ethers");
  const coder = AbiCoder.defaultAbiCoder();
  const encoded = coder.encode(["address", "address"], [buintAddr, deployer]);
  const constructorArgsHex = encoded.startsWith("0x") ? encoded.slice(2) : encoded;

  const bunitAirdropContractName =
    process.env.BUNIT_AIRDROP_CONTRACT_NAME || "project/src/b-unit/BUnitAirdrop.sol:BUnitAirdrop";

  console.log("\n[2] 验证 BUnitAirdrop (Standard JSON)...");
  const bunitAirdropSources = getBUnitAirdropSources(fullInput);
  console.log("  包含", bunitAirdropSources.length, "个源文件");
  let r2 = await verifyViaStandardJson(
    airdropAddr,
    bunitAirdropContractName,
    bunitAirdropSources,
    fullInput,
    constructorArgsHex
  );

  const tryHardhat = process.argv.includes("--try-hardhat") || (!r2.ok && !process.argv.includes("--no-hardhat-fallback"));
  if (tryHardhat) {
    console.log("\n  尝试 Hardhat verify (需 --network conet)...");
    try {
      const { execSync } = await import("child_process");
      const args = [
        "npx", "hardhat", "verify", "blockscout", "--network", "conet",
        "--contract", "src/b-unit/BUnitAirdrop.sol:BUnitAirdrop",
        airdropAddr, buintAddr, deployer,
      ];
      execSync(args.join(" "), { stdio: "inherit", cwd: path.join(__dirname, "..") });
      r2 = { ok: true, message: "Hardhat verify 成功" };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const stderr = (err as { stderr?: Buffer })?.stderr?.toString() ?? "";
      const fullMsg = msg + stderr;
      console.error("  Hardhat verify 失败:", msg);
      if (fullMsg.toLowerCase().includes("already verified")) r2 = { ok: true, message: "already verified" };
    }
  }

  if (r2.ok) {
    console.log("  ✅ BUnitAirdrop 验证成功");
  } else {
    console.error("  ❌ BUnitAirdrop 验证失败:", r2.message);
    if (!r2.message.toLowerCase().includes("already verified")) process.exit(1);
  }

  console.log("\n✅ 全部验证完成！");
  console.log("  BUint: " + BLOCKSCOUT_UI + "/address/" + buintAddr);
  console.log("  BUnitAirdrop: " + BLOCKSCOUT_UI + "/address/" + airdropAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
