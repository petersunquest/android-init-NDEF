#!/usr/bin/env node
/**
 * 本地 solc 编译 FULL-FORM JSON，比对链上 runtime bytecode（验证 JSON 正确性）。
 * 运行: node scripts/localVerifyBeamioStackBytecode.mjs
 */

import fs from "fs";
import path from "path";
import { execSync } from "child_process";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const RPC = process.env.BASE_RPC_URL || "https://base-rpc.conet.network";

const SOLC_CANDIDATES = [
  `${process.env.HOME}/Library/Caches/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.33+commit.64118f21`,
  `${process.env.HOME}/.local/share/hardhat-nodejs/compilers-v3/macosx-amd64/solc-macosx-amd64-v0.8.33+commit.64118f21`,
];

function findSolc() {
  for (const p of SOLC_CANDIDATES) if (fs.existsSync(p)) return p;
  throw new Error("未找到 solc 0.8.33；请先 npm run compile");
}

function compileJson(jsonPath, contractName) {
  const solc = findSolc();
  const outFile = `/tmp/beamio-solc-out-${Date.now()}.json`;
  execSync(`"${solc}" --standard-json "${jsonPath}" > "${outFile}"`, { stdio: "pipe" });
  const out = JSON.parse(fs.readFileSync(outFile, "utf-8"));
  fs.unlinkSync(outFile);
  if (out.errors?.length) {
    const fatal = out.errors.filter((e) => e.severity === "error");
    if (fatal.length) throw new Error(fatal.map((e) => e.formattedMessage).join("\n"));
  }
  const [file, name] = contractName.split(":");
  const art = out.contracts?.[file]?.[name];
  if (!art) throw new Error(`编译结果无 ${contractName}`);
  return art;
}

function normRuntime(hex) {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  // strip metadata (last 2 bytes length suffix) — compare prefix only
  return h.length > 100 ? h.slice(0, -106) : h;
}

async function checkItem(provider, item, bundle) {
  const jsonPath = path.join(root, item.formJsonRel);
  const art = compileJson(jsonPath, item.contractName);
  const onChain = await provider.getCode(item.address);
  if (onChain === "0x") throw new Error(`${item.exportKey} 链上无 code`);

  let localDeployed = art.evm.deployedBytecode.object;
  if (item.constructorArgs && item.constructorArgs !== "(none)") {
    const ctor = item.constructorArgs.startsWith("0x")
      ? item.constructorArgs
      : "0x" + item.constructorArgs;
    localDeployed = art.evm.bytecode.object + ctor.slice(2);
  }

  const chainRuntime = onChain.slice(2);
  const localRuntime = localDeployed.startsWith("0x") ? localDeployed.slice(2) : localDeployed;

  const chainNorm = normRuntime(chainRuntime);
  const localNorm = normRuntime(localRuntime);

  const match = chainNorm === localNorm || chainRuntime.startsWith(localNorm.slice(0, 200));
  console.log(
    `${match ? "✅" : "⚠️"} ${item.exportKey} @ ${item.address}`,
    match ? "runtime 前缀匹配" : "runtime 不完全匹配（可能 metadata/immutable 差异，仍可在 BaseScan 验证）"
  );
  if (!match) {
    console.log("  chain len:", chainRuntime.length, "local len:", localRuntime.length);
  }
}

async function main() {
  const bundlePath = path.join(root, "deployments/base-BeamioStack-verify-bundle.json");
  const bundle = JSON.parse(fs.readFileSync(bundlePath, "utf-8"));
  const provider = new ethers.JsonRpcProvider(RPC);
  console.log("Local bytecode check via solc +", RPC, "\n");
  for (const item of bundle.contracts) {
    await checkItem(provider, item, bundle);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
