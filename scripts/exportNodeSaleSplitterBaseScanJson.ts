/**
 * 导出 NodeSaleSplitter BaseScan 手动验证所需的两份 Standard JSON 到 deployments/：
 *   - base-NodeSaleSplitter-impl-standard-input.json  （implementation，0.8.35 / viaIR）
 *   - base-NodeSaleSplitter-proxy-standard-input.json  （OpenZeppelin ERC1967Proxy，0.8.27）
 * 并打印每个合约在 BaseScan 表单需要填写的字段（Contract Name / Compiler / Constructor Args）。
 *
 * 运行: npx tsx scripts/exportNodeSaleSplitterBaseScanJson.ts
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

const IMPL_ROOT_SOURCE = "project/src/mainnet/NodeSaleSplitter.sol";
const IMPL_CONTRACT_NAME = "project/src/mainnet/NodeSaleSplitter.sol:NodeSaleSplitter";
const IMPL_COMPILER_VERSION = "v0.8.35+commit.47b9dedd";

const ERC1967_PROXY_OZ_ABS = path.join(
  root,
  "node_modules/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol"
);
const ERC1967_PROXY_CONTRACT_NAME =
  "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy";
const OZ_ERC1967_PROXY_COMPILER_VERSION = "v0.8.27+commit.40a35a09";

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
  if (!fs.existsSync(p)) throw new Error("未找到 deployments/base-NodeSaleSplitter.json");
  return JSON.parse(fs.readFileSync(p, "utf-8")) as Deployment;
}

function buildOzProxyStandardJson(): {
  language: string;
  sources: SourceMap;
  settings: Record<string, unknown>;
} {
  if (!fs.existsSync(ERC1967_PROXY_OZ_ABS)) {
    throw new Error(`OpenZeppelin 源码不存在: ${ERC1967_PROXY_OZ_ABS}`);
  }
  const sources: SourceMap = {};
  collectSources(root, ERC1967_PROXY_OZ_ABS, sources);
  return {
    language: "Solidity",
    sources,
    settings: {
      metadata: { bytecodeHash: "none" },
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",
      viaIR: false,
      remappings: [],
      outputSelection: {
        "*": {
          "": ["ast"],
          "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "evm.methodIdentifiers", "metadata"],
        },
      },
    },
  };
}

function main() {
  const d = loadDeployment();
  const outDir = path.join(root, "deployments");

  // 1) implementation
  const { standardJson: implJson, sourceCount } = exportBasescanStandardJsonFromRoot(
    root,
    IMPL_ROOT_SOURCE
  );
  const implOut = path.join(outDir, "base-NodeSaleSplitter-impl-standard-input.json");
  fs.writeFileSync(implOut, JSON.stringify(implJson, null, 2) + "\n", "utf-8");

  // 2) proxy + constructor args
  const proxyJson = buildOzProxyStandardJson();
  const proxyOut = path.join(outDir, "base-NodeSaleSplitter-proxy-standard-input.json");
  fs.writeFileSync(proxyOut, JSON.stringify(proxyJson, null, 2) + "\n", "utf-8");

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
    .encode(["address", "bytes"], [d.implementation, initData])
    .slice(2);

  console.log("=".repeat(64));
  console.log("NodeSaleSplitter — BaseScan 手动验证素材已导出");
  console.log("=".repeat(64));
  console.log("\n[1] IMPLEMENTATION");
  console.log("  Address:        ", d.implementation);
  console.log("  JSON file:      ", path.relative(root, implOut), `(${sourceCount} sources)`);
  console.log("  Type:            Solidity (Standard-Json-Input)");
  console.log("  Compiler:       ", IMPL_COMPILER_VERSION);
  console.log("  Contract Name:  ", IMPL_CONTRACT_NAME);
  console.log("  Constructor Args:(留空)");

  console.log("\n[2] ERC1967 PROXY (canonical)");
  console.log("  Address:        ", d.address);
  console.log("  JSON file:      ", path.relative(root, proxyOut));
  console.log("  Type:            Solidity (Standard-Json-Input)");
  console.log("  Compiler:       ", OZ_ERC1967_PROXY_COMPILER_VERSION);
  console.log("  Contract Name:  ", ERC1967_PROXY_CONTRACT_NAME);
  console.log("  Constructor Args (ABI-encoded, 不含 0x):");
  console.log("    " + proxyCtorHex);
  console.log("\n  提示: 也可在 BaseScan 代理页点 'Is this a proxy?' 自动识别 implementation。");
}

main();
