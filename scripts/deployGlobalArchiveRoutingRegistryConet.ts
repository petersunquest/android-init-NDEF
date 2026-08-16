/**
 * Deploy GlobalArchiveRoutingRegistryV1 (UUPS) on CoNET L1 and register
 * bootstrap group 1 with seven unique archive participant wallets.
 *
 * CoNET only (chainId 224422). Canonical address = DLEERC1967Proxy.
 * Does not write explorer hostnames into the contract.
 *
 * Run:
 *   npm run compile
 *   npx hardhat run scripts/deployGlobalArchiveRoutingRegistryConet.ts --network conet
 *
 * Env:
 *   DRY_RUN=1 — skip broadcast
 *   DLE_ROUTING_INITIAL_OWNER — initial owner (default deployer)
 *
 * After deploy this task must verify on Blockscout in the same session:
 *   node scripts/verifyGlobalArchiveRoutingRegistryConet.mjs --submit
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, "..");

const ADDRESSES_PATH = path.join(ROOT, "deployments", "conet-addresses.json");
const OUT_PATH = path.join(ROOT, "deployments", "conet-GlobalArchiveRoutingRegistry.json");
const LOCAL_WALLETS_PATH = path.join(os.homedir(), ".dle-archive-participant-wallets.local.json");
const EXPLORER_WALLETS_PATH = path.join(
  ROOT,
  "src/conet-layer2/explorer/src/fixtures/labArchiveWallets.ts",
);
const EXPLORER_ROUTING_PATH = path.join(
  ROOT,
  "src/conet-layer2/explorer/src/config/l1Routing.ts",
);
const INVENTORY_PATH = path.join(
  ROOT,
  "src/conet-layer2/pilot/inventories/conet-dle-30d-lab-2026-08.json",
);

const LAB_ROSTER = [
  { domainId: "fd-01-ionos-45", role: "active" },
  { domainId: "fd-02-ionos-189", role: "active" },
  { domainId: "fd-03-ionos-98", role: "active" },
  { domainId: "fd-04-hosthatch-tokyo1", role: "active" },
  { domainId: "fd-05-hosthatch-tokyo2", role: "active" },
  { domainId: "fd-06-ionos-174", role: "standby" },
  { domainId: "fd-07-ionos-207", role: "standby" },
] as const;

function loadJson(file: string): Record<string, unknown> {
  if (!fs.existsSync(file)) return {};
  return JSON.parse(fs.readFileSync(file, "utf8")) as Record<string, unknown>;
}

function writeJson(file: string, value: unknown): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function loadOrCreateParticipantWallets(ethers: {
  Wallet: { createRandom: () => { address: string; privateKey: string } };
  getAddress: (value: string) => string;
}): Array<{ domainId: string; role: string; address: string; privateKey: string }> {
  if (fs.existsSync(LOCAL_WALLETS_PATH)) {
    const existing = JSON.parse(fs.readFileSync(LOCAL_WALLETS_PATH, "utf8")) as {
      wallets?: Array<{ domainId?: string; address?: string; privateKey?: string }>;
    };
    const rows = existing.wallets ?? [];
    if (rows.length === LAB_ROSTER.length) {
      const reused = LAB_ROSTER.map((slot, index) => {
        const row = rows[index];
        if (!row?.address || !row.privateKey) {
          throw new Error(`${LOCAL_WALLETS_PATH} is missing address/privateKey at index ${index}`);
        }
        return {
          domainId: slot.domainId,
          role: slot.role,
          address: ethers.getAddress(row.address),
          privateKey: row.privateKey.startsWith("0x") ? row.privateKey : `0x${row.privateKey}`,
        };
      });
      const unique = new Set(reused.map((row) => row.address.toLowerCase()));
      if (unique.size !== LAB_ROSTER.length) {
        throw new Error(`${LOCAL_WALLETS_PATH} does not contain 7 unique wallets`);
      }
      console.log("reusing participant wallets from", LOCAL_WALLETS_PATH);
      return reused;
    }
  }

  const created = LAB_ROSTER.map((slot) => {
    const wallet = ethers.Wallet.createRandom();
    return {
      domainId: slot.domainId,
      role: slot.role,
      address: wallet.address,
      privateKey: wallet.privateKey,
    };
  });
  writeJson(LOCAL_WALLETS_PATH, {
    schema: "dle-archive-participant-wallets-v1",
    createdAt: new Date().toISOString(),
    note: "Private keys stay on this machine only. Do not copy across hosts or commit.",
    wallets: created,
  });
  fs.chmodSync(LOCAL_WALLETS_PATH, 0o600);
  console.log("wrote participant private keys to", LOCAL_WALLETS_PATH);
  return created;
}

function writeExplorerWallets(
  wallets: Array<{ domainId: string; address: string }>,
  proxyAddress: string,
): void {
  const mapLines = wallets
    .map((row) => `  '${row.domainId}': '${row.address}',`)
    .join("\n");
  fs.writeFileSync(
    EXPLORER_WALLETS_PATH,
    `/** Local-first seed of L1 participant wallets. RPC success may overwrite. */\n` +
      `export const LAB_ARCHIVE_WALLETS: Record<string, string> = {\n${mapLines}\n}\n`,
    "utf8",
  );

  const routing = fs.readFileSync(EXPLORER_ROUTING_PATH, "utf8");
  const next = routing.replace(
    /export const CONET_GLOBAL_ARCHIVE_ROUTING_REGISTRY = '[^']*'/,
    `export const CONET_GLOBAL_ARCHIVE_ROUTING_REGISTRY = '${proxyAddress}'`,
  );
  if (next === routing && !routing.includes(proxyAddress)) {
    throw new Error(`failed to patch ${EXPLORER_ROUTING_PATH} with proxy address`);
  }
  fs.writeFileSync(EXPLORER_ROUTING_PATH, next, "utf8");
}

function writeInventoryAddresses(wallets: Array<{ domainId: string; address: string }>): void {
  if (!fs.existsSync(INVENTORY_PATH)) return;
  const inventory = JSON.parse(fs.readFileSync(INVENTORY_PATH, "utf8")) as {
    domains?: Array<Record<string, unknown>>;
  };
  if (!Array.isArray(inventory.domains)) return;
  const byDomain = new Map(wallets.map((row) => [row.domainId, row.address]));
  for (const domain of inventory.domains) {
    const domainId = typeof domain.domainId === "string" ? domain.domainId : "";
    const address = byDomain.get(domainId);
    if (address) domain.participantWallet = address;
  }
  writeJson(INVENTORY_PATH, inventory);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`Expected CoNET chainId 224422, got ${net.chainId}`);
  }

  const initialOwner = process.env.DLE_ROUTING_INITIAL_OWNER || deployer.address;
  const wallets = loadOrCreateParticipantWallets(ethers);
  const active = wallets.slice(0, 5).map((row) => row.address);
  const standby = wallets.slice(5, 7).map((row) => row.address);

  console.log("=".repeat(60));
  console.log("Deploy GlobalArchiveRoutingRegistryV1 (UUPS) on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("initialOwner:", initialOwner);
  console.log(
    "deployer CNET balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
  );
  for (const row of wallets) {
    console.log(`  ${row.domainId} (${row.role}): ${row.address}`);
  }

  if (process.env.DRY_RUN === "1") {
    console.log("DRY_RUN=1 — skip broadcast");
    return;
  }

  const Impl = await ethers.getContractFactory("GlobalArchiveRoutingRegistryV1");
  const impl = await Impl.deploy();
  await impl.waitForDeployment();
  const implAddress = await impl.getAddress();
  const implTx = impl.deploymentTransaction();
  console.log("[1] implementation:", implAddress);

  const initData = Impl.interface.encodeFunctionData("initialize", [initialOwner]);
  const Proxy = await ethers.getContractFactory("DLEERC1967Proxy");
  const proxy = await Proxy.deploy(implAddress, initData);
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();
  const proxyTx = proxy.deploymentTransaction();
  console.log("[2] proxy (canonical):", proxyAddress);

  const registry = Impl.attach(proxyAddress);
  const groupKeyHash = ethers.id("dle.lab.group-1.key");
  const membershipRoot = ethers.id("dle.lab.group-1.membership");
  const standbyRoot = ethers.id("dle.lab.group-1.standby");
  const registerTx = await registry.registerLiveGroup(
    active,
    standby,
    groupKeyHash,
    membershipRoot,
    standbyRoot,
    1,
  );
  const registerReceipt = await registerTx.wait();
  console.log("[3] registerLiveGroup groupId=1 tx:", registerTx.hash);

  const liveIds: bigint[] = await registry.liveGroupIds();
  const archives: string[] = await registry.archivesOf(1);
  if (liveIds.length !== 1 || liveIds[0] !== 1n) {
    throw new Error(`liveGroupIds() mismatch: ${liveIds.join(",")}`);
  }
  if (archives.length !== 7) throw new Error("archivesOf(1) did not return 7 wallets");
  for (let i = 0; i < 7; i += 1) {
    if (ethers.getAddress(archives[i]) !== ethers.getAddress(wallets[i].address)) {
      throw new Error(`archivesOf(1)[${i}] != ${wallets[i].domainId}`);
    }
  }
  console.log("[4] liveGroupIds:", liveIds.map(String).join(","));
  console.log("[4] archivesOf(1) matches 7 lab participant wallets");

  const deployBlock = await ethers.provider.getBlockNumber();
  const roster = wallets.map((row, index) => ({
    index,
    domainId: row.domainId,
    role: row.role,
    participantWallet: row.address,
  }));

  const out = {
    schema: "conet-dle-global-routing-v1",
    recordState: "deployed",
    network: "conet",
    chainId: 224422,
    compiler: {
      solcVersion: "0.8.35",
      viaIR: true,
      evmVersion: "cancun",
      optimizerRuns: 0,
      metadataBytecodeHash: "none",
    },
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    deployBlock,
    implementation: implAddress,
    proxy: proxyAddress,
    initializeArgs: { initialOwner },
    bootstrapGroup: {
      groupId: 1,
      keyEpoch: 1,
      membershipEpoch: 1,
      groupKeyHash,
      membershipRoot,
      standbyRoot,
      registerTxHash: registerTx.hash,
      registerBlock: registerReceipt?.blockNumber ?? null,
    },
    roster,
    components: [
      {
        key: "GlobalArchiveRoutingRegistryV1Implementation",
        kind: "implementation",
        sourceKey: "project/src/dle/GlobalArchiveRoutingRegistryV1.sol",
        contractName: "GlobalArchiveRoutingRegistryV1",
        address: implAddress,
        deploymentTxHash: implTx?.hash ?? null,
        deploymentBlock: implTx?.blockNumber ?? deployBlock,
      },
      {
        key: "GlobalArchiveRoutingRegistryV1Proxy",
        kind: "proxy",
        sourceKey: "project/src/dle/DLEERC1967Proxy.sol",
        contractName: "DLEERC1967Proxy",
        implementationKey: "GlobalArchiveRoutingRegistryV1Implementation",
        initializer: {
          signature: "initialize(address)",
          args: [initialOwner],
        },
        address: proxyAddress,
        deploymentTxHash: proxyTx?.hash ?? null,
        deploymentBlock: proxyTx?.blockNumber ?? deployBlock,
      },
    ],
    nextSteps: {
      verify: "node scripts/verifyGlobalArchiveRoutingRegistryConet.mjs --submit",
    },
  };

  writeJson(OUT_PATH, out);
  const addresses = loadJson(ADDRESSES_PATH);
  addresses.GlobalArchiveRoutingRegistry = proxyAddress;
  addresses.GlobalArchiveRoutingRegistryImpl = implAddress;
  writeJson(ADDRESSES_PATH, addresses);
  writeExplorerWallets(wallets, proxyAddress);
  writeInventoryAddresses(wallets);

  console.log("saved:", OUT_PATH);
  console.log("updated explorer seed + inventory addresses (no private keys)");
  console.log("Explorer proxy:", `https://mainnet.conet.network/address/${proxyAddress}`);
  console.log("Explorer impl:", `https://mainnet.conet.network/address/${implAddress}`);
  console.log("\nNext:");
  console.log("  node scripts/verifyGlobalArchiveRoutingRegistryConet.mjs --submit");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
