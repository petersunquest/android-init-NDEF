/**
 * CoNET Blockscout 验证 ConetTeamCnetHold（UUPS impl + ERC1967 proxy）。
 *
 *   node scripts/exportStandardJsonFromBuildInfo.mjs ConetTeamCnetHold --full
 *   npx tsx scripts/verifyConetTeamCnetHoldConet.ts
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder, getAddress, Interface } from "ethers";
import { fileURLToPath } from "url";
import {
  collectSources,
  exportBasescanStandardJsonFromRoot,
  type SourceMap,
} from "./basescanStandardJsonShared.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");
const CONET_RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const IMPL_COMPILER_VERSION = "v0.8.35+commit.47b9dedd";
const OZ_ERC1967_PROXY_COMPILER_VERSION = "v0.8.27+commit.40a35a09";

const IMPL_ROOT_SOURCE = "project/src/mainnet/ConetTeamCnetHold.sol";
const IMPL_CONTRACT_NAME = "project/src/mainnet/ConetTeamCnetHold.sol:ConetTeamCnetHold";
const ERC1967_PROXY_OZ_ABS = path.join(
  root,
  "node_modules/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol"
);
const ERC1967_PROXY_CONTRACT_NAME =
  "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy";

type Deployment = {
  address: string;
  proxy?: string;
  implementation: string;
  owner?: string;
  initialAdmin?: string;
  initialRedeemAdmin?: string;
  startTimestamp?: string;
  initializeArgs?: {
    owner?: string;
    startTimestamp?: string;
    initialAdmin?: string;
    initialRedeemAdmin?: string;
  };
};

function loadDeployment(): Deployment {
  const p = path.join(root, "deployments/conet-ConetTeamCnetHold.json");
  if (!fs.existsSync(p)) {
    throw new Error(
      "未找到 deployments/conet-ConetTeamCnetHold.json\n请先运行: npx hardhat run scripts/deployConetTeamCnetHoldProxyToConet.ts --network conet"
    );
  }
  return JSON.parse(fs.readFileSync(p, "utf-8")) as Deployment;
}

function resolveInit(d: Deployment): {
  owner: string;
  startTimestamp: bigint;
  initialAdmin: string;
  initialRedeemAdmin: string;
} {
  const owner = getAddress(d.initializeArgs?.owner || d.owner || "");
  const initialAdmin = getAddress(d.initializeArgs?.initialAdmin || d.initialAdmin || "");
  const initialRedeemAdmin = getAddress(
    d.initializeArgs?.initialRedeemAdmin || d.initialRedeemAdmin || ""
  );
  const startRaw = d.initializeArgs?.startTimestamp || d.startTimestamp;
  if (!startRaw) throw new Error("deployments JSON 缺少 startTimestamp");
  return { owner, startTimestamp: BigInt(startRaw), initialAdmin, initialRedeemAdmin };
}

function buildOzProxyStandardJsonSettings() {
  return {
    metadata: { bytecodeHash: "ipfs" as const },
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

function exportOzProxyStandardJson(): {
  language: string;
  sources: SourceMap;
  settings: ReturnType<typeof buildOzProxyStandardJsonSettings>;
} {
  if (!fs.existsSync(ERC1967_PROXY_OZ_ABS)) {
    throw new Error(`OpenZeppelin 源码不存在: ${ERC1967_PROXY_OZ_ABS}`);
  }
  const sources: SourceMap = {};
  collectSources(root, ERC1967_PROXY_OZ_ABS, sources);
  return { language: "Solidity", sources, settings: buildOzProxyStandardJsonSettings() };
}

async function rpcHasCode(address: string): Promise<boolean> {
  const res = await fetch(CONET_RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method: "eth_getCode", params: [address, "latest"], id: 1 }),
  });
  const data = (await res.json()) as { result?: string };
  return typeof data.result === "string" && data.result.length > 2;
}

async function checkVerified(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (!res.ok) return false;
  const data = (await res.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string | null;
  };
  return Boolean(data.is_verified || data.is_partially_verified || data.source_code);
}

async function waitVerified(address: string, label: string): Promise<void> {
  const max = Number(process.env.CONET_VERIFY_POLL_MAX || 90);
  for (let i = 0; i < max; i++) {
    if (await checkVerified(address)) {
      console.log(`✅ ${label} 已验证: ${BLOCKSCOUT_UI}/address/${address}#code`);
      return;
    }
    await new Promise((r) => setTimeout(r, 4000));
  }
  throw new Error(`${label} 验证轮询超时: ${address}`);
}

async function submitImplVerify(impl: string, standardJson: string): Promise<void> {
  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${impl}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", IMPL_COMPILER_VERSION);
  form.set("contract_name", IMPL_CONTRACT_NAME);
  form.set("autodetect_constructor_args", "true");
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJson], { type: "application/json" }), "standard-input.json");

  console.log(`\nPOST impl @ ${impl}`);
  console.log("  contract_name:", IMPL_CONTRACT_NAME);
  console.log("  standard-input bytes:", standardJson.length);

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  let out: { message?: string };
  try {
    out = JSON.parse(text) as { message?: string };
  } catch {
    console.error(text.slice(0, 2000));
    throw new Error(`非 JSON HTTP ${res.status}`);
  }
  console.log(" ", JSON.stringify(out));
  if (!res.ok || !/verification started|already verified/i.test(out.message ?? "")) {
    throw new Error(`impl 提交失败: ${out.message ?? text.slice(0, 300)}`);
  }
}

async function submitProxyLegacy(
  proxy: string,
  impl: string,
  init: { owner: string; startTimestamp: bigint; initialAdmin: string; initialRedeemAdmin: string }
): Promise<void> {
  const initIface = new Interface([
    "function initialize(address owner_, uint64 startTimestamp_, address initialAdmin_, address initialRedeemAdmin_)",
  ]);
  const initData = initIface.encodeFunctionData("initialize", [
    init.owner,
    init.startTimestamp,
    init.initialAdmin,
    init.initialRedeemAdmin,
  ]);
  const ctor = AbiCoder.defaultAbiCoder().encode(["address", "bytes"], [impl, initData]).slice(2);
  const proxyJson = JSON.stringify(exportOzProxyStandardJson());

  const body = new URLSearchParams();
  body.set("addressHash", proxy);
  body.set("contractaddress", proxy);
  body.set("contractname", ERC1967_PROXY_CONTRACT_NAME);
  body.set("compilerversion", OZ_ERC1967_PROXY_COMPILER_VERSION);
  body.set("codeformat", "solidity-standard-json-input");
  body.set("sourceCode", proxyJson);
  body.set("contractSourceCode", proxyJson);
  body.set("constructorArguments", ctor);
  body.set("autodetectConstructorArguments", "false");

  console.log(`\nPOST (legacy) proxy @ ${proxy}`);
  console.log("  constructor_args:", ctor);

  const res = await fetch(`${BLOCKSCOUT_UI}/api?module=contract&action=verifysourcecode`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const out = (await res.json()) as { status?: string; result?: string; message?: string };
  console.log(" ", JSON.stringify(out));
  const guid = out.result;
  if (out.status !== "1" || !guid) {
    throw new Error(`proxy legacy 提交失败: ${out.message ?? out.result ?? "unknown"}`);
  }
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 4000));
    const c = await fetch(`${BLOCKSCOUT_UI}/api?module=contract&action=checkverifystatus&guid=${guid}`);
    const ct = (await c.json()) as { result?: string };
    if (/pass|verified|already/i.test(ct.result ?? "")) {
      console.log(`✅ proxy 已验证: ${BLOCKSCOUT_UI}/address/${proxy}#code`);
      return;
    }
    if (/fail|error/i.test(ct.result ?? "")) {
      throw new Error(`proxy legacy 验证失败: ${ct.result}`);
    }
  }
  throw new Error(`proxy legacy 验证轮询超时: ${proxy}`);
}

async function main() {
  const d = loadDeployment();
  const proxyAddr = getAddress(d.proxy || d.address);
  const implAddr = getAddress(d.implementation);
  const init = resolveInit(d);

  console.log("=".repeat(60));
  console.log("CoNET Blockscout 验证 ConetTeamCnetHold");
  console.log("=".repeat(60));
  console.log("proxy:", proxyAddr);
  console.log("implementation:", implAddr);
  console.log("initialize:", init);

  if (!(await rpcHasCode(implAddr))) throw new Error(`impl 无 code: ${implAddr}`);
  if (!(await rpcHasCode(proxyAddr))) throw new Error(`proxy 无 code: ${proxyAddr}`);

  const { standardJson, sourceCount } = exportBasescanStandardJsonFromRoot(root, IMPL_ROOT_SOURCE);
  const implStandardJson = JSON.stringify(standardJson);
  console.log("\n[1/2] impl Standard JSON prune sources:", sourceCount, "bytes:", implStandardJson.length);

  if (await checkVerified(implAddr)) {
    console.log("skip impl (already verified):", implAddr);
  } else {
    await submitImplVerify(implAddr, implStandardJson);
    await waitVerified(implAddr, "impl");
  }

  console.log("\n[2/2] proxy ERC1967 (legacy partial) ...");
  if (await checkVerified(proxyAddr)) {
    console.log("skip proxy (already verified):", proxyAddr);
  } else {
    await submitProxyLegacy(proxyAddr, implAddr, init);
  }

  console.log("\n完成。查看:", `${BLOCKSCOUT_UI}/address/${proxyAddr}#code`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
