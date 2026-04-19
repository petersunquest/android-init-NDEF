/**
 * 部署 src/mainnet/AccountRegistry.sol 到 CoNET (chainId 224422)。
 * 构造函数无参数；部署者自动成为首个 _admin。
 *
 * 运行: npx hardhat run scripts/deployAccountRegistryToConet.ts --network conet
 *
 * 可选环境变量:
 *   SKIP_VERIFY=1  — 跳过 Blockscout 验证
 *   SKIP_REF_PATCH=1 — 不将各子项目中误用的旧地址替换为新 AccountRegistry 地址
 *
 * 前置: ~/.master.json 中配置部署私钥（与 conet 网络一致），且账户有足够 CNET gas。
 */

import { network as networkModule } from "hardhat";
import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

/** 子项目中若仍写死此 AccountRegistry 地址，部署新注册表时会被替换为本次部署地址。 */
const ACCOUNT_REGISTRY_ADDRESS_IN_SOURCES = "0x2dF9c4c51564FfF861965572CE11ebe27d3C1B35";

const REF_FILES_TO_PATCH = [
  "scripts/addBeamioAdminsToAccountRegistry.ts",
  "scripts/diagnoseRestoreWithUserPin.ts",
  "scripts/fetchCardOwnerBeamioTag.ts",
  "scripts/API server/util.ts",
  "src/x402sdk/src/util.ts",
  "src/x402sdk/src/db.ts",
  "src/bizSite/src/services/beamio.ts",
  "src/SilentPassUI/src/services/beamio.ts",
  "src/beamio.app/src/services/beamio.ts",
  "src/Alliance/src/services/beamio.ts",
  "src/android-NDEF/app/src/main/java/com/beamio/android_ntag/BeamioOnboardingApi.kt",
  "src/android-NDEF/app/src/main/java/com/beamio/android_ntag/BeamioWalletService.kt",
  "src/CashTrees_iOS/iOS_NDEF/iOS_NDEF/BeamioConstants.swift",
];

function patchLegacyRegistryAddress(newAddr: string) {
  const re = new RegExp(ACCOUNT_REGISTRY_ADDRESS_IN_SOURCES, "gi");
  for (const rel of REF_FILES_TO_PATCH) {
    const full = path.join(root, rel);
    if (!fs.existsSync(full)) continue;
    const content = fs.readFileSync(full, "utf-8");
    const next = content.replace(re, newAddr);
    if (next !== content) {
      fs.writeFileSync(full, next, "utf-8");
      console.log("  patched:", rel);
    }
  }
}

function mergeConetAddresses(accountRegistry: string, deployer: string, txHash: string) {
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) {
    console.warn("  skip conet-addresses.json merge: file missing");
    return;
  }
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
  data.AccountRegistry = accountRegistry;
  data.accountRegistryDeployer = deployer;
  data.accountRegistryDeployedAt = new Date().toISOString();
  data.accountRegistryTx = txHash;
  fs.writeFileSync(addrPath, JSON.stringify(data, null, 2) + "\n", "utf-8");
  console.log("  merged AccountRegistry into deployments/conet-addresses.json");
}

/** Blockscout v2：multipart + 最小 standard JSON（见 verifyAccountRegistryConetStandardJson.ts） */
function verifyViaStandardJson(address: string): void {
  execSync("npx tsx scripts/verifyAccountRegistryConetStandardJson.ts", {
    stdio: "inherit",
    cwd: root,
    env: { ...process.env, ACCOUNT_REGISTRY_ADDRESS: address },
  });
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) {
    throw new Error("无签名账户：请配置 ~/.master.json（conet 网络）或 PRIVATE_KEY");
  }
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  console.log("=".repeat(60));
  console.log("Deploy AccountRegistry on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "native");

  const Factory = await ethers.getContractFactory("AccountRegistry");
  const reg = await Factory.deploy();
  await reg.waitForDeployment();
  const address = await reg.getAddress();
  const txHash = reg.deploymentTransaction()?.hash ?? "";

  console.log("\n✅ AccountRegistry:", address);
  console.log("   tx:", txHash);

  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const outPath = path.join(deploymentsDir, "conet-AccountRegistry.json");
  const artifact = {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "AccountRegistry",
    source: "src/mainnet/AccountRegistry.sol",
    address,
    deployer: deployer.address,
    constructorArgs: [],
    timestamp: new Date().toISOString(),
    transactionHash: txHash,
  };
  fs.writeFileSync(outPath, JSON.stringify(artifact, null, 2) + "\n", "utf-8");
  console.log("saved:", outPath);

  mergeConetAddresses(address, deployer.address, txHash);

  if (process.env.SKIP_REF_PATCH !== "1" && process.env.SKIP_REF_PATCH !== "true") {
    console.log("\n替换子项目中写死的 AccountRegistry 地址为本次部署地址…");
    patchLegacyRegistryAddress(address);
  }

  if (process.env.SKIP_VERIFY === "1" || process.env.SKIP_VERIFY === "true") {
    console.log("\nSKIP_VERIFY=1，跳过验证。可稍后执行:");
    console.log(`  ACCOUNT_REGISTRY_ADDRESS=${address} npx tsx scripts/verifyAccountRegistryConetStandardJson.ts`);
    printManualVerifyHint(address);
    return;
  }

  console.log("\n导出最小 standard-input JSON（供 v2 验证）…");
  try {
    execSync("node scripts/exportAccountRegistryConetStandardJson.mjs", { stdio: "inherit", cwd: root });
  } catch {
    console.warn("⚠️  导出失败（是否未 compile？）。将尝试由验证脚本从 build-info 直接读取。");
  }

  console.log("\n等待 10s 后提交 Blockscout v2 standard-input 验证…");
  await new Promise((r) => setTimeout(r, 10000));
  try {
    verifyViaStandardJson(address);
    console.log("\n✅ 已提交验证（Explorer 异步编译；几秒后可刷新合约页）");
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("\n⚠️ 验证脚本失败:", msg);
    printManualVerifyHint(address);
    process.exitCode = 1;
  }
}

function printManualVerifyHint(address: string) {
  console.log("\n--- Standard JSON 验证（推荐）---");
  console.log("  node scripts/exportAccountRegistryConetStandardJson.mjs");
  console.log(`  ACCOUNT_REGISTRY_ADDRESS=${address} npx tsx scripts/verifyAccountRegistryConetStandardJson.ts`);
  console.log("\n--- 或浏览器表单 / 单文件 flatten ---");
  console.log(`合约: ${address}`);
  console.log("浏览器: https://mainnet.conet.network/address/" + address);
  console.log("Compiler: v0.8.33+commit.64118f21, runs=0, viaIR, evm cancun, metadata.bytecodeHash=none");
  console.log("Constructor arguments: 无");
  console.log("单文件: npx hardhat flatten src/mainnet/AccountRegistry.sol");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
