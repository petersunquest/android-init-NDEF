/**
 * 通过 flattened 源码在 CoNET Explorer 验证 BUint 与 BUnitAirdrop
 * 解决 hardhat verify 的 413 Request Entity Too Large 错误
 *
 * 前置: 需先 flatten 生成文件
 * 运行: npx tsx scripts/verifyBUintAirdropViaFlattened.ts
 *
 * 或手动验证: https://mainnet.conet.network/contract-verification
 * 选择 "Via flattened source code"
 */

import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const BLOCKSCOUT_API = "https://mainnet.conet.network/api";
const COMPILER_VERSION = "v0.8.33+commit.64118f21";

const deployPath = path.join(__dirname, "../deployments/conet-BUintAirdrop.json");
const deploy = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
const buintAddr = deploy.contracts?.BUint?.address;
const airdropAddr = deploy.contracts?.BUnitAirdrop?.address;
const deployer = deploy.deployer;

if (!buintAddr || !airdropAddr || !deployer) {
  throw new Error("部署文件缺少 BUint / BUnitAirdrop 地址或 deployer");
}

async function verifyViaFlattened(
  address: string,
  contractName: string,
  sourcePath: string,
  constructorArgsHex: string
) {
  let sourceCode = fs.readFileSync(sourcePath, "utf-8");
  sourceCode = sourceCode.replace(/^\[dotenv[^\n]*\n/, "");

  const body = {
    compiler_version: COMPILER_VERSION,
    license_type: "mit",
    source_code: sourceCode,
    is_optimization_enabled: true,
    optimization_runs: 1,
    contract_name: contractName,
    constructor_arguments: constructorArgsHex,
    autodetect_constructor_args: false,
    evm_version: "osaka",
    via_ir: true,
  };

  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${address}/verification/via/flattened-code`;
  console.log("POST", url);
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`验证失败: ${res.status} ${JSON.stringify(data)}`);
  }
  console.log("  result:", data);
  return true;
}

async function main() {
  console.log("=".repeat(60));
  console.log("验证 BUint 与 BUnitAirdrop (via flattened)");
  console.log("=".repeat(60));
  console.log("BUint:", buintAddr);
  console.log("BUnitAirdrop:", airdropAddr);

  const projectRoot = path.join(__dirname, "..");

  // 1. Flatten BUint
  const buintFlatPath = path.join(projectRoot, "scripts/BUint_flat.sol");
  console.log("\n[1] Flatten BUint...");
  execSync(`npx hardhat flatten src/b-unit/BUint.sol 2>/dev/null > ${buintFlatPath}`, {
    cwd: projectRoot,
  });

  // 2. Verify BeamioBUnits (no constructor args)
  console.log("\n[2] 验证 BeamioBUnits...");
  try {
    await verifyViaFlattened(buintAddr, "BeamioBUnits", buintFlatPath, "");
    console.log("  ✅ BeamioBUnits 验证成功");
  } catch (e) {
    const msg = (e as Error)?.message ?? "";
    if (msg.includes("already verified") || msg.includes("Already Verified")) {
      console.log("  ⏭️ BeamioBUnits 已验证");
    } else {
      throw e;
    }
  }

  // 3. Flatten BUnitAirdrop
  const airdropFlatPath = path.join(projectRoot, "scripts/BUnitAirdrop_flat.sol");
  console.log("\n[3] Flatten BUnitAirdrop...");
  execSync(`npx hardhat flatten src/b-unit/BUnitAirdrop.sol 2>/dev/null > ${airdropFlatPath}`, {
    cwd: projectRoot,
  });

  // 4. Verify BUnitAirdrop (constructor: _bunit, initialOwner)
  const { AbiCoder } = await import("ethers");
  const coder = AbiCoder.defaultAbiCoder();
  const encoded = coder.encode(["address", "address"], [buintAddr, deployer]);
  const constructorArgsHex = encoded.startsWith("0x") ? encoded.slice(2) : encoded;

  console.log("\n[4] 验证 BUnitAirdrop...");
  try {
    await verifyViaFlattened(airdropAddr, "BUnitAirdrop", airdropFlatPath, constructorArgsHex);
    console.log("  ✅ BUnitAirdrop 验证成功");
  } catch (e) {
    const msg = (e as Error)?.message ?? "";
    if (msg.includes("already verified") || msg.includes("Already Verified")) {
      console.log("  ⏭️ BUnitAirdrop 已验证");
    } else {
      throw e;
    }
  }

  console.log("\n✅ 全部验证完成！");
  console.log("  BUint: https://mainnet.conet.network/address/" + buintAddr);
  console.log("  BUnitAirdrop: https://mainnet.conet.network/address/" + airdropAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
