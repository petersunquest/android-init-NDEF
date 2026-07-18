/**
 * Verify both new CoNET UUPS stacks immediately after deployment.
 *
 * Implementations use Blockscout v2 standard-input.
 * ERC1967 proxies use the legacy endpoint because OZ proxy metadata commonly
 * produces a partial match rather than a v2 full match.
 */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { AbiCoder, Interface, getAddress } from "ethers";
import {
  collectSources,
  exportBasescanStandardJsonFromRoot,
  type SourceMap,
} from "./basescanStandardJsonShared.js";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const api = (process.env.CONET_BLOCKSCOUT_API || "https://mainnet.conet.network/api").replace(/\/$/, "");
const ui = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");
const rpc = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const deploymentPath = path.join(root, "deployments/conet-ReferralRegistryVaultV1-stack.json");
const compiler = "v0.8.35+commit.47b9dedd";
const proxyCompiler = "v0.8.27+commit.40a35a09";
const proxySource = path.join(root, "node_modules/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol");
const proxyName = "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy";

type Target = {
  key: "ReferralRegistryVaultV1" | "BUnitAirdropV2";
  source: string;
  contractName: string;
  initTypes: string[];
};

const targets: Target[] = [
  {
    key: "ReferralRegistryVaultV1",
    source: "project/src/mainnet/ReferralRegistryVaultV1.sol",
    contractName: "ReferralRegistryVaultV1",
    initTypes: ["address", "address", "address", "address", "address"],
  },
  {
    key: "BUnitAirdropV2",
    source: "project/src/b-unit/BUnitAirdropV2.sol",
    contractName: "BUnitAirdropV2",
    initTypes: ["address", "address", "address", "address", "address"],
  },
];

function load(): any {
  return JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
}

async function hasCode(address: string): Promise<boolean> {
  const r = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"] }),
  });
  const j = (await r.json()) as { result?: string };
  return Boolean(j.result && j.result !== "0x");
}

async function assertImplementationMatches(target: Target, address: string): Promise<void> {
  const artifactPath =
    target.key === "BUnitAirdropV2"
      ? path.join(root, "artifacts/src/b-unit/BUnitAirdropV2.sol/BUnitAirdropV2.json")
      : path.join(root, "artifacts/src/mainnet/ReferralRegistryVaultV1.sol/ReferralRegistryVaultV1.json");
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8")) as {
    deployedBytecode: string;
  };
  const local = artifact.deployedBytecode.replace(/^0x/, "").toLowerCase();
  const response = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"] }),
  });
  const chainResult = (await response.json()) as { result?: string };
  const chain = (chainResult.result || "").replace(/^0x/, "").toLowerCase();
  const self = address.slice(2).toLowerCase();
  const immutableBytes = `0`.repeat(24) + self;
  let patched = local;
  for (let position = chain.indexOf(immutableBytes); position >= 0; position = chain.indexOf(immutableBytes, position + 1)) {
    patched = patched.slice(0, position) + immutableBytes + patched.slice(position + immutableBytes.length);
  }
  if (patched !== chain) {
    throw new Error(`${target.key} implementation bytecode mismatch with eth_getCode`);
  }
  console.log(`✅ ${target.key} implementation bytecode matches chain (UUPS immutable slots normalized)`);
}

async function verified(address: string): Promise<boolean> {
  const r = await fetch(`${api}/v2/smart-contracts/${address}`);
  if (!r.ok) return false;
  const j = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean; source_code?: string };
  return Boolean(j.is_verified || j.is_partially_verified || j.source_code);
}

async function waitVerified(address: string, label: string): Promise<void> {
  const max = Number(process.env.CONET_VERIFY_POLL_MAX || 180);
  for (let i = 0; i < max; i++) {
    if (await verified(address)) {
      console.log(`✅ ${label}: ${ui}/address/${address}#code`);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 4000));
  }
  throw new Error(`${label} verification timed out: ${address}`);
}

async function submitImpl(target: Target, address: string): Promise<void> {
  const { standardJson, sourceCount } = exportBasescanStandardJsonFromRoot(root, target.source);
  const form = new FormData();
  form.set("compiler_version", compiler);
  form.set("contract_name", `${target.source}:${target.contractName}`);
  form.set("autodetect_constructor_args", "true");
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([JSON.stringify(standardJson)], { type: "application/json" }), "standard-input.json");
  console.log(`submit ${target.key} implementation ${address} (${sourceCount} sources)`);
  const r = await fetch(`${api}/v2/smart-contracts/${address}/verification/via/standard-input`, {
    method: "POST",
    body: form,
  });
  const text = await r.text();
  let j: { message?: string };
  try {
    j = JSON.parse(text) as { message?: string };
  } catch {
    throw new Error(`implementation response ${r.status}: ${text.slice(0, 500)}`);
  }
  console.log(j);
  if (!r.ok || !/verification started|already verified/i.test(j.message || "")) {
    throw new Error(`implementation verification rejected: ${j.message || text.slice(0, 500)}`);
  }
  await waitVerified(address, `${target.key} implementation`);
}

function proxyJson(): string {
  const sources: SourceMap = {};
  collectSources(root, proxySource, sources);
  return JSON.stringify({
    language: "Solidity",
    sources,
    settings: {
      metadata: { bytecodeHash: "ipfs" },
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
  });
}

async function submitProxy(
  target: Target,
  proxy: string,
  implementation: string,
  args: unknown[]
): Promise<void> {
  const init = new Interface([
    `function initialize(${target.initTypes.map((t, i) => `${t} a${i}`).join(",")})`,
  ]).encodeFunctionData("initialize", args);
  const constructorArgs = AbiCoder.defaultAbiCoder().encode(["address", "bytes"], [implementation, init]).slice(2);
  const body = new URLSearchParams();
  body.set("addressHash", proxy);
  body.set("contractaddress", proxy);
  body.set("contractname", proxyName);
  body.set("compilerversion", proxyCompiler);
  body.set("codeformat", "solidity-standard-json-input");
  body.set("sourceCode", proxyJson());
  body.set("constructorArguments", constructorArgs);
  body.set("autodetectConstructorArguments", "false");
  const r = await fetch(`${ui}/api?module=contract&action=verifysourcecode`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const j = (await r.json()) as { status?: string; result?: string; message?: string };
  console.log(j);
  if (j.status !== "1" || !j.result) throw new Error(`proxy verification rejected: ${j.message || j.result}`);
  for (let i = 0; i < 90; i++) {
    await new Promise((resolve) => setTimeout(resolve, 4000));
    const s = await fetch(`${ui}/api?module=contract&action=checkverifystatus&guid=${j.result}`);
    const sj = (await s.json()) as { result?: string };
    if (/pass|verified|already/i.test(sj.result || "")) {
      console.log(`✅ ${target.key} proxy: ${ui}/address/${proxy}#code`);
      return;
    }
    if (/fail|error/i.test(sj.result || "")) throw new Error(`proxy verification failed: ${sj.result}`);
  }
  throw new Error(`proxy verification timed out: ${proxy}`);
}

async function main() {
  const d = load();
  for (const target of targets) {
    const c = d.contracts[target.key];
    const proxy = getAddress(c.proxy);
    const implementation = getAddress(c.upgradedImplementation || c.implementation);
    if (!(await hasCode(proxy)) || !(await hasCode(implementation))) throw new Error(`${target.key} missing code`);
    await assertImplementationMatches(target, implementation);
    if (!(await verified(implementation))) await submitImpl(target, implementation);
    else console.log(`skip already verified implementation ${implementation}`);
    if (!(await verified(proxy))) {
      await submitProxy(target, proxy, implementation, c.initializeArgs);
    } else {
      console.log(`skip already verified proxy ${proxy}`);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
