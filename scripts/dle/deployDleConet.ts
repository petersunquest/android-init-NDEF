/**
 * Deploy the remaining CoNET-DLE MVP UUPS stack on CoNET L1 (chainId 224422).
 *
 * Does not redeploy GlobalArchiveRoutingRegistry (already live).
 * Canonical addresses are DLEERC1967Proxy instances. Does not write
 * explorer hostnames or dle.conet.network into Solidity.
 *
 * Run:
 *   npm run compile
 *   npx hardhat run scripts/dle/deployDleConet.ts --network conet
 *
 * Env:
 *   DRY_RUN=1 — skip broadcast
 *   DLE_INITIAL_OWNER — initial owner (default deployer)
 *   DLE_CHAIN_REGISTRY_URI — ERC-1155 uri (must already HTTP 200 on an existing domain)
 *   DISPUTE_CHALLENGE_PERIOD_SECONDS — default 86400
 *   DISPUTE_MINIMUM_BOND_WEI — default 0.01 ether
 *   FORCE_EXIT_CHALLENGE_PERIOD_SECONDS — default 86400
 *   NORMAL_EXIT_TIMEOUT_SECONDS — default 604800
 *
 * After deploy this task must verify on Blockscout in the same session:
 *   node scripts/dle/verifyDleConet.mjs --skip-compile --submit
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  DLE_CHAIN_ID,
  DLE_COMPONENT_BY_KEY,
  DLE_COMPONENTS,
  DLE_RECORD_SCHEMA,
  DLE_SOLC_VERSION,
} from "./deploymentManifest.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, "../..");
const TEMPLATE_PATH = path.join(ROOT, "deployments", "conet-DLE-MVP.template.json");
const OUT_PATH = path.join(ROOT, "deployments", "conet-DLE-MVP.json");
const ADDRESSES_PATH = path.join(ROOT, "deployments", "conet-addresses.json");

const DEFAULT_URI = "https://mainnet.conet.network/dle/erc1155/metadata.json";
const DEFAULT_DISPUTE_PERIOD = "86400";
const DEFAULT_DISPUTE_BOND_WEI = "10000000000000000";
const DEFAULT_FORCE_EXIT_PERIOD = "86400";
const DEFAULT_NORMAL_EXIT_TIMEOUT = "604800";

type ComponentRecord = {
  key: string;
  kind: "implementation" | "proxy";
  sourceKey: string;
  contractName: string;
  implementationKey?: string;
  initializer?: { signature: string; args: unknown[] };
  address: string | null;
  deploymentTxHash: string | null;
  deploymentBlock: number | null;
};

function readJson(file: string) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJson(file: string, value: unknown) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function assertHttpOk(url: string) {
  return fetch(url, { method: "HEAD" }).then(async (response) => {
    if (response.ok) return;
    const get = await fetch(url);
    if (!get.ok) {
      throw new Error(`DLE_CHAIN_REGISTRY_URI must already return HTTP 200: ${url} → ${get.status}`);
    }
  });
}

function resolvePlaceholder(raw: unknown, bindings: Record<string, string>, field: string): string {
  if (typeof raw !== "string") {
    throw new Error(`${field} must be a string placeholder or value`);
  }
  if (!raw.startsWith("$")) return raw;
  const resolved = bindings[raw.slice(1)] ?? bindings[raw];
  if (!resolved) throw new Error(`${field} unresolved placeholder ${raw}`);
  return resolved;
}

function loadPartialRecord() {
  if (!fs.existsSync(OUT_PATH)) return null;
  const existing = readJson(OUT_PATH);
  if (existing?.schema !== DLE_RECORD_SCHEMA) return null;
  return existing;
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== BigInt(DLE_CHAIN_ID)) {
    throw new Error(`Expected CoNET chainId ${DLE_CHAIN_ID}, got ${net.chainId}`);
  }

  const owner = process.env.DLE_INITIAL_OWNER || deployer.address;
  const chainRegistryUri = process.env.DLE_CHAIN_REGISTRY_URI || DEFAULT_URI;
  const disputeChallengePeriodSeconds =
    process.env.DISPUTE_CHALLENGE_PERIOD_SECONDS || DEFAULT_DISPUTE_PERIOD;
  const disputeMinimumBondWei = process.env.DISPUTE_MINIMUM_BOND_WEI || DEFAULT_DISPUTE_BOND_WEI;
  const forceExitChallengePeriodSeconds =
    process.env.FORCE_EXIT_CHALLENGE_PERIOD_SECONDS || DEFAULT_FORCE_EXIT_PERIOD;
  const normalExitTimeoutSeconds =
    process.env.NORMAL_EXIT_TIMEOUT_SECONDS || DEFAULT_NORMAL_EXIT_TIMEOUT;

  if (chainRegistryUri.includes("dle.conet.network")) {
    throw new Error("Do not write dle.conet.network into the chain-registry URI");
  }
  await assertHttpOk(chainRegistryUri);

  const template = readJson(TEMPLATE_PATH);
  const partial = loadPartialRecord();
  const existingByKey = new Map<string, ComponentRecord>(
    (partial?.components ?? []).map((row: ComponentRecord) => [row.key, row]),
  );

  const bindings: Record<string, string> = {
    OWNER: owner,
    DLE_CHAIN_REGISTRY_URI: chainRegistryUri,
    DISPUTE_CHALLENGE_PERIOD_SECONDS: disputeChallengePeriodSeconds,
    DISPUTE_MINIMUM_BOND_WEI: disputeMinimumBondWei,
    FORCE_EXIT_CHALLENGE_PERIOD_SECONDS: forceExitChallengePeriodSeconds,
    NORMAL_EXIT_TIMEOUT_SECONDS: normalExitTimeoutSeconds,
  };

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("=".repeat(60));
  console.log("Deploy CoNET-DLE MVP UUPS stack on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("initialOwner:", owner);
  console.log("deployer CNET balance:", ethers.formatEther(balance));
  console.log("chainRegistryUri:", chainRegistryUri);
  console.log("disputeChallengePeriodSeconds:", disputeChallengePeriodSeconds);
  console.log("disputeMinimumBondWei:", disputeMinimumBondWei);
  console.log("forceExitChallengePeriodSeconds:", forceExitChallengePeriodSeconds);
  console.log("normalExitTimeoutSeconds:", normalExitTimeoutSeconds);

  if (process.env.DRY_RUN === "1") {
    console.log("DRY_RUN=1 — skip broadcast");
    return;
  }

  const deployed: ComponentRecord[] = [];

  const persist = (deployBlock: number) => {
    const record = {
      schema: DLE_RECORD_SCHEMA,
      recordState: "deployed",
      network: "conet",
      chainId: DLE_CHAIN_ID,
      compiler: {
        solcVersion: DLE_SOLC_VERSION,
        viaIR: true,
        evmVersion: "cancun",
        optimizerRuns: 0,
        metadataBytecodeHash: "none",
      },
      deployer: deployer.address,
      timestamp: new Date().toISOString(),
      deployBlock,
      configuration: {
        owner,
        chainRegistryUri,
        disputeChallengePeriodSeconds,
        disputeMinimumBondWei,
        forceExitChallengePeriodSeconds,
        normalExitTimeoutSeconds,
      },
      components: deployed,
      libraries: [],
      verification: {
        blockscoutV2: {
          status: "not-started",
          completedAt: null,
        },
      },
      nextSteps: {
        verify: "node scripts/dle/verifyDleConet.mjs --skip-compile --submit",
      },
    };
    writeJson(OUT_PATH, record);
    const addresses = readJson(ADDRESSES_PATH);
    for (const component of deployed) {
      if (!component.address) continue;
      if (component.kind === "implementation") {
        addresses[`${component.contractName}Impl`] = component.address;
        continue;
      }
      const implementation = DLE_COMPONENT_BY_KEY[component.implementationKey ?? ""];
      if (!implementation?.contractName) {
        throw new Error(`${component.key} is missing implementationKey for address book`);
      }
      addresses[implementation.contractName] = component.address;
    }
    delete addresses.DLEERC1967Proxy;
    writeJson(ADDRESSES_PATH, addresses);
  };

  for (const expected of DLE_COMPONENTS) {
    const templateRow = template.components.find((row: ComponentRecord) => row.key === expected.key);
    if (!templateRow) throw new Error(`template missing ${expected.key}`);
    const previous = existingByKey.get(expected.key);
    if (previous?.address && previous.deploymentTxHash && previous.deploymentBlock != null) {
      const code = await ethers.provider.getCode(previous.address);
      if (code !== "0x") {
        if (previous.kind === "proxy" && previous.implementationKey) {
          bindings[previous.key] = previous.address;
        }
        deployed.push(previous);
        console.log(`[resume] ${expected.key}: ${previous.address}`);
        persist(previous.deploymentBlock);
        continue;
      }
    }

    if (expected.kind === "implementation") {
      const factory = await ethers.getContractFactory(expected.contractName);
      const impl = await factory.deploy();
      await impl.waitForDeployment();
      const tx = impl.deploymentTransaction();
      const receipt = await tx?.wait();
      const row: ComponentRecord = {
        key: expected.key,
        kind: "implementation",
        sourceKey: expected.sourceKey,
        contractName: expected.contractName,
        address: await impl.getAddress(),
        deploymentTxHash: tx?.hash ?? null,
        deploymentBlock: receipt?.blockNumber ?? Number(await ethers.provider.getBlockNumber()),
      };
      deployed.push(row);
      console.log(`[impl] ${expected.key}: ${row.address}`);
      persist(row.deploymentBlock ?? 0);
      continue;
    }

    const implementation = deployed.find((row) => row.key === expected.implementationKey);
    if (!implementation?.address) {
      throw new Error(`${expected.key} is missing implementation ${expected.implementationKey}`);
    }
    const factory = await ethers.getContractFactory(
      DLE_COMPONENT_BY_KEY[expected.implementationKey].contractName,
    );
    const rawArgs = templateRow.initializer?.args ?? [];
    const args = rawArgs.map((value: unknown, index: number) =>
      resolvePlaceholder(value, bindings, `${expected.key}.initializer.args[${index}]`),
    );
    const initData = factory.interface.encodeFunctionData("initialize", args);
    const Proxy = await ethers.getContractFactory("DLEERC1967Proxy");
    const proxy = await Proxy.deploy(implementation.address, initData);
    await proxy.waitForDeployment();
    const tx = proxy.deploymentTransaction();
    const receipt = await tx?.wait();
    const address = await proxy.getAddress();
    bindings[expected.key] = address;
    const row: ComponentRecord = {
      key: expected.key,
      kind: "proxy",
      sourceKey: expected.sourceKey,
      contractName: expected.contractName,
      implementationKey: expected.implementationKey,
      initializer: {
        signature: expected.initializerSignature,
        args,
      },
      address,
      deploymentTxHash: tx?.hash ?? null,
      deploymentBlock: receipt?.blockNumber ?? Number(await ethers.provider.getBlockNumber()),
    };
    deployed.push(row);
    console.log(`[proxy] ${expected.key}: ${row.address}`);
    persist(row.deploymentBlock ?? 0);
  }

  const lastBlock = deployed.at(-1)?.deploymentBlock ?? Number(await ethers.provider.getBlockNumber());
  persist(lastBlock);
  console.log("saved:", OUT_PATH);
  console.log("\nNext:");
  console.log("  node scripts/dle/verifyDleConet.mjs --skip-compile --submit");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
