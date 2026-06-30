/**
 * BaseScan Standard JSON 验证 NodeSaleSplitter（UUPS 实现 + ERC1967 代理）。
 *
 * via-IR 下使用递归依赖剪枝的 FULL-FORM Standard JSON（仅 NodeSaleSplitter.sol 的完整 import 闭包），
 * settings 与 hardhat.config.ts 一致（0.8.35 / viaIR / runs=0 / cancun / bytecodeHash none）。
 *
 * 运行: BASESCAN_API_KEY=... npx tsx scripts/verifyNodeSaleSplitterBaseScan.ts
 * 部署信息从 deployments/base-NodeSaleSplitter.json 读取。
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { AbiCoder, Interface } from "ethers";
import {
  collectSources,
  exportBasescanStandardJsonFromRoot,
  type SourceMap,
} from "./basescanStandardJsonShared.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const BASESCAN_API = "https://api.basescan.org/api";
const CHAIN_ID = 8453;
/** NodeSaleSplitter 新部署：solc 0.8.35（见 beamio-solc-compiler-version.mdc）。 */
const IMPL_COMPILER_VERSION = "v0.8.35+commit.47b9dedd";
/** OpenZeppelin @5.4.0 预编译 ERC1967Proxy artifact 的 solc。 */
const OZ_ERC1967_PROXY_COMPILER_VERSION = "v0.8.27+commit.40a35a09";

const IMPL_ROOT_SOURCE = "project/src/mainnet/NodeSaleSplitter.sol";
const IMPL_CONTRACT_NAME = "project/src/mainnet/NodeSaleSplitter.sol:NodeSaleSplitter";
const ERC1967_PROXY_OZ_ABS = path.join(
  root,
  "node_modules/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol"
);
const ERC1967_PROXY_CONTRACT_NAME = "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy";

type Deployment = {
  address: string;
  implementation: string;
  usdc: string;
  treasury: string;
  serverFeeRecipient: string;
  nodePriceUsdc6: string;
  serverFeeUsdc6: string;
  admin: string;
};

function loadDeployment(): Deployment {
  const p = path.join(root, "deployments/base-NodeSaleSplitter.json");
  if (!fs.existsSync(p)) {
    throw new Error(
      "未找到 deployments/base-NodeSaleSplitter.json\n请先运行: npx hardhat run scripts/deployNodeSaleSplitterToBase.ts --network base"
    );
  }
  return JSON.parse(fs.readFileSync(p, "utf-8")) as Deployment;
}

function buildOzProxyStandardJsonSettings() {
  return {
    metadata: { bytecodeHash: "none" as const },
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "cancun" as const,
    viaIR: false,
    remappings: [] as string[],
    outputSelection: {
      "*": {
        "": ["ast"],
        "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
      },
    },
  };
}

function exportOzProxyStandardJson(): { language: string; sources: SourceMap; settings: ReturnType<typeof buildOzProxyStandardJsonSettings> } {
  if (!fs.existsSync(ERC1967_PROXY_OZ_ABS)) {
    throw new Error(`OpenZeppelin 源码不存在: ${ERC1967_PROXY_OZ_ABS}（请先 npm install）`);
  }
  const sources: SourceMap = {};
  collectSources(root, ERC1967_PROXY_OZ_ABS, sources);
  return { language: "Solidity", sources, settings: buildOzProxyStandardJsonSettings() };
}

async function submitVerify(
  address: string,
  contractName: string,
  compilerVersion: string,
  standardJson: string,
  constructorArgsHex: string
): Promise<{ ok: boolean; message: string }> {
  const apiKey = process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY;
  if (!apiKey) return { ok: false, message: "未设置 BASESCAN_API_KEY 或 ETHERSCAN_API_KEY" };

  const params = new URLSearchParams();
  params.append("module", "contract");
  params.append("action", "verifysourcecode");
  params.append("chainid", String(CHAIN_ID));
  params.append("contractaddress", address);
  params.append("sourceCode", standardJson);
  params.append("codeformat", "solidity-standard-json-input");
  params.append("contractname", contractName);
  params.append("compilerversion", compilerVersion);
  params.append("optimizationUsed", "1");
  params.append("runs", "0");
  params.append("constructorArguements", constructorArgsHex);
  params.append("apikey", apiKey);
  params.append("licenseType", "3"); // MIT

  const res = await fetch(BASESCAN_API, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });
  const data = (await res.json().catch(() => ({}))) as { status?: string; result?: string; message?: string };
  if (!res.ok || process.env.VERBOSE) {
    console.log("  API:", res.status, JSON.stringify(data));
  }
  const ok =
    res.ok &&
    (data.status === "1" ||
      (data.message?.toLowerCase().includes("successfully") ?? false) ||
      (data.message?.toLowerCase().includes("already verified") ?? false) ||
      (data.result?.toLowerCase().includes("guid") ?? false));
  return { ok, message: data.result || data.message || JSON.stringify(data) };
}

async function main() {
  const d = loadDeployment();
  const proxyAddr = d.address;
  const implAddr = d.implementation;

  console.log("=".repeat(60));
  console.log("BaseScan 验证 NodeSaleSplitter");
  console.log("=".repeat(60));
  console.log("proxy:", proxyAddr);
  console.log("implementation:", implAddr);

  // 1) 实现合约（必须验证）——递归剪枝 FULL-FORM + 0.8.35。
  console.log("\n[1/2] 验证 implementation ...");
  const { standardJson: implJson, sourceCount } = exportBasescanStandardJsonFromRoot(root, IMPL_ROOT_SOURCE);
  console.log("  sources:", sourceCount, "| compiler:", IMPL_COMPILER_VERSION);
  const implRes = await submitVerify(
    implAddr,
    IMPL_CONTRACT_NAME,
    IMPL_COMPILER_VERSION,
    JSON.stringify(implJson),
    ""
  );
  if (implRes.ok) {
    console.log("  ✅ implementation 验证已提交:", implRes.message);
    console.log("     https://basescan.org/address/" + implAddr + "#code");
  } else {
    console.error("  ❌ implementation 验证失败:", implRes.message);
    if (!implRes.message.toLowerCase().includes("already verified")) process.exit(1);
  }

  // 2) ERC1967 代理（尽力验证；失败不阻断——BaseScan 可自动识别 EIP-1967 代理）。
  console.log("\n[2/2] 验证 ERC1967Proxy（尽力）...");
  const initIface = new Interface([
    "function initialize(address usdc,address treasury,address serverFeeRecipient,uint256 nodePriceUsdc6,uint256 serverFeeUsdc6,address admin)",
  ]);
  const initData = initIface.encodeFunctionData("initialize", [
    d.usdc,
    d.treasury,
    d.serverFeeRecipient,
    BigInt(d.nodePriceUsdc6),
    BigInt(d.serverFeeUsdc6),
    d.admin,
  ]);
  const proxyCtorHex = AbiCoder.defaultAbiCoder()
    .encode(["address", "bytes"], [implAddr, initData])
    .slice(2);
  const proxyJson = exportOzProxyStandardJson();
  const proxyRes = await submitVerify(
    proxyAddr,
    ERC1967_PROXY_CONTRACT_NAME,
    OZ_ERC1967_PROXY_COMPILER_VERSION,
    JSON.stringify(proxyJson),
    proxyCtorHex
  );
  if (proxyRes.ok) {
    console.log("  ✅ proxy 验证已提交:", proxyRes.message);
  } else {
    console.warn("  ⚠️  proxy 验证未通过（可在 BaseScan 用 'Is this a proxy?' 自动识别 impl）:", proxyRes.message);
  }
  console.log("     https://basescan.org/address/" + proxyAddr + "#code");

  console.log("\n验证可能需要 30 秒至数分钟，请稍后在 BaseScan 查看。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
