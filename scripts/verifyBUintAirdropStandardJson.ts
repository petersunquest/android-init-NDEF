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

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_URL = "https://mainnet.conet.network";
const COMPILER_VERSION = "v0.8.33+commit.64118f21";

// BUint 无依赖，仅需自身
const BUINT_SOURCES = ["project/src/b-unit/BUint.sol"];

// BUnitAirdrop：使用 build-info 中所有 b-unit 与 contracts 源（确保 bytecode 完全匹配）
function getBUnitAirdropSources(fullInput: { sources: Record<string, unknown> }): string[] {
  return Object.keys(fullInput.sources).filter(
    (k) => k.startsWith("project/src/b-unit") || k.startsWith("project/src/contracts")
  );
}

async function verifyViaStandardJson(
  address: string,
  contractName: string,
  sourceKeys: string[],
  fullInput: { language: string; sources: Record<string, { content: string }>; settings: Record<string, unknown> },
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

  const v2Url = `${BASE_URL}/api/v2/smart-contracts/${address}/verification/via/standard-input`;
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
  const fullInput = buildInfo.input as {
    language: string;
    sources: Record<string, { content: string }>;
    settings: Record<string, unknown>;
  };

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
    const r1 = await verifyViaStandardJson(buintAddr, "project/src/b-unit/BUint.sol:BeamioBUnits", BUINT_SOURCES, fullInput, "");
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

  const bunitAirdropContractName = "project/src/b-unit/BUnitAirdrop.sol:BUnitAirdrop";

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
  console.log("  BUint: https://mainnet.conet.network/address/" + buintAddr);
  console.log("  BUnitAirdrop: https://mainnet.conet.network/address/" + airdropAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
