/**
 * Deploy DeveloperTokenFxRegistry (UUPS), wire GBToken admin + Settlement,
 * upgrade DepinGbSettlement1155 implementation (PayByUse path), verify on Blockscout.
 *
 * Run:
 *   npm run compile
 *   npx hardhat run scripts/deployDeveloperTokenFxRegistryAndUpgradeSettlementConet.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const SETTLEMENT_PATH = path.join(__dirname, "..", "deployments", "conet-DepinGbSettlement1155.json");
const OUT_PATH = path.join(__dirname, "..", "deployments", "conet-DeveloperTokenFxRegistry.json");
const MASTER_PATH = path.join(homedir(), ".master.json");

const DEFAULT_GB = "0xC3EF02DaE632b4C10abB66e07d92a387c10838D8";

function loadJson(p: string): Record<string, unknown> {
  if (!fs.existsSync(p)) return {};
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

function loadSettleAdmins(): string[] {
  if (!fs.existsSync(MASTER_PATH)) return [];
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  return (data?.settle_contractAdmin || []).map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`));
}

async function main() {
  const settleDeploy = loadJson(SETTLEMENT_PATH) as {
    proxy?: string;
    implementation?: string;
    initializeArgs?: Record<string, string>;
  };
  const settlementProxy =
    process.env.SETTLEMENT_PROXY ||
    settleDeploy.proxy ||
    (loadJson(ADDRESSES_PATH).DepinGbSettlement1155 as string);
  if (!settlementProxy) throw new Error("Missing Settlement proxy address");

  const gbToken =
    process.env.GB_TOKEN_ERC20 ||
    settleDeploy.initializeArgs?.gbToken ||
    (loadJson(ADDRESSES_PATH).GBToken as string) ||
    DEFAULT_GB;

  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`Expected 224422, got ${net.chainId}`);

  console.log("=".repeat(60));
  console.log("Deploy DeveloperTokenFxRegistry + upgrade Settlement");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("GBToken:", gbToken);
  console.log("Settlement proxy:", settlementProxy);

  // ---- Registry ----
  const RegImpl = await ethers.getContractFactory("DeveloperTokenFxRegistry");
  const regImpl = await RegImpl.deploy();
  await regImpl.waitForDeployment();
  const regImplAddr = await regImpl.getAddress();
  console.log("[1] Registry impl:", regImplAddr);

  const regInit = RegImpl.interface.encodeFunctionData("initialize", [
    deployer.address,
    gbToken,
    settlementProxy,
  ]);
  const RegProxy = await ethers.getContractFactory("DeveloperTokenFxRegistryProxy");
  const regProxy = await RegProxy.deploy(regImplAddr, regInit);
  await regProxy.waitForDeployment();
  const regProxyAddr = await regProxy.getAddress();
  console.log("[2] Registry proxy:", regProxyAddr);

  const gb = await ethers.getContractAt("GBTokenV2", gbToken);
  const txGb = await gb.addAdmin(regProxyAddr);
  await txGb.wait();
  console.log("[3] GBToken.addAdmin(registry) ok");

  const registry = RegImpl.attach(regProxyAddr);
  for (const pk of loadSettleAdmins()) {
    const addr = new ethers.Wallet(pk).address;
    if (addr.toLowerCase() === deployer.address.toLowerCase()) continue;
    const tx = await registry.addAdmin(addr);
    await tx.wait();
    console.log("[4] registry.addAdmin(", addr, ")");
  }

  // ---- Upgrade Settlement ----
  const SetImpl = await ethers.getContractFactory("DepinGbSettlement1155");
  const newSetImpl = await SetImpl.deploy();
  await newSetImpl.waitForDeployment();
  const newSetImplAddr = await newSetImpl.getAddress();
  console.log("[5] Settlement new impl:", newSetImplAddr);

  const settlement = SetImpl.attach(settlementProxy);
  const txUp = await settlement.upgradeToAndCall(newSetImplAddr, "0x");
  await txUp.wait();
  console.log("[6] Settlement upgradeToAndCall ok");

  const txWire = await settlement.setDeveloperTokenFxRegistry(regProxyAddr);
  await txWire.wait();
  console.log("[7] Settlement.setDeveloperTokenFxRegistry ok");

  const out = {
    network: "conet",
    chainId: "224422",
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    implementation: regImplAddr,
    proxy: regProxyAddr,
    settlementProxy,
    settlementImplementationNew: newSetImplAddr,
    settlementImplementationOld: settleDeploy.implementation,
    initializeArgs: {
      initialAdmin: deployer.address,
      gbToken,
      settlement: settlementProxy,
    },
  };
  fs.writeFileSync(OUT_PATH, JSON.stringify(out, null, 2) + "\n");
  console.log("saved:", OUT_PATH);

  // Update settlement deploy json
  settleDeploy.implementation = newSetImplAddr;
  settleDeploy.developerTokenFxRegistry = regProxyAddr;
  (settleDeploy as { upgradedAt?: string }).upgradedAt = out.timestamp;
  fs.writeFileSync(SETTLEMENT_PATH, JSON.stringify(settleDeploy, null, 2) + "\n");

  const addresses = loadJson(ADDRESSES_PATH);
  addresses.DeveloperTokenFxRegistry = regProxyAddr;
  addresses.DeveloperTokenFxRegistryImpl = regImplAddr;
  addresses.DepinGbSettlement1155Impl = newSetImplAddr;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n");

  console.log("\n[8] Verifying on Blockscout…");
  const v1 = spawnSync(
    "node",
    ["--import", "tsx", path.join(__dirname, "verifyDepinGbSettlement1155Conet.ts")],
    {
      cwd: path.join(__dirname, ".."),
      stdio: "inherit",
      env: { ...process.env, IMPL: newSetImplAddr, PROXY: settlementProxy },
    },
  );
  if (v1.status !== 0) throw new Error("Settlement re-verify failed");

  const v2 = spawnSync(
    "node",
    ["--import", "tsx", path.join(__dirname, "verifyDeveloperTokenFxRegistryConet.ts")],
    { cwd: path.join(__dirname, ".."), stdio: "inherit", env: process.env },
  );
  if (v2.status !== 0) throw new Error("Registry verify failed");

  console.log("\nDone.");
  console.log("Settlement:", settlementProxy);
  console.log("Registry:", regProxyAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
