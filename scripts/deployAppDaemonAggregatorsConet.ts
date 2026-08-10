/**
 * Deploy Multicall3 + BeamioConsumerWalletDashboard (UUPS) on CoNET for App Daemon.
 *
 * Run from BeamioContract root:
 *   npm run compile
 *   npx hardhat run scripts/deployAppDaemonAggregatorsConet.ts --network conet
 *
 * After deploy: verify per conet-deploy-verify-on-the-spot.mdc
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const MULTICALL_OUT = path.join(__dirname, "..", "deployments", "conet-Multicall3.json");
const DASH_OUT = path.join(__dirname, "..", "deployments", "conet-BeamioConsumerWalletDashboard.json");

const CONET_USDC = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";
const CONET_GB = "0xC3EF02DaE632b4C10abB66e07d92a387c10838D8";
const CONET_VDR = "0xc71e246DD78B37C2fABc905D340932F28F503433";
const CONET_REFERRAL = "0xD6252Cbf266B80231397Ac2a4f25ed2d9b01DEE6";

function loadAddressesJson(): Record<string, unknown> {
  if (!fs.existsSync(ADDRESSES_PATH)) return {};
  return JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
}

async function main() {
  if (process.env.DRY_RUN === "1") {
    console.log("DRY_RUN=1 — skip deploy");
    return;
  }

  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`Expected CoNET chainId 224422, got ${net.chainId}`);
  }

  console.log("=".repeat(60));
  console.log("Deploy App Daemon aggregators on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // ---- Multicall3 ----
  let multicallAddr = process.env.EXISTING_MULTICALL3 || "";
  if (!multicallAddr) {
    const Mc = await ethers.getContractFactory("Multicall3");
    const mc = await Mc.deploy();
    await mc.waitForDeployment();
    multicallAddr = await mc.getAddress();
    console.log("[1] Multicall3:", multicallAddr);
  } else {
    console.log("[1] Multicall3 (existing):", multicallAddr);
  }

  fs.mkdirSync(path.dirname(MULTICALL_OUT), { recursive: true });
  fs.writeFileSync(
    MULTICALL_OUT,
    JSON.stringify(
      {
        network: "conet",
        chainId: "224422",
        deployer: deployer.address,
        timestamp: new Date().toISOString(),
        Multicall3: multicallAddr,
        note: "Standard Multicall3 aggregate3 for App Daemon / Discover / Coupon batching",
      },
      null,
      2,
    ) + "\n",
    "utf-8",
  );

  // ---- Dashboard UUPS ----
  const initialAdmin = process.env.DASHBOARD_INITIAL_ADMIN || deployer.address;
  const Impl = await ethers.getContractFactory("BeamioConsumerWalletDashboard");
  const impl = await Impl.deploy();
  await impl.waitForDeployment();
  const implAddress = await impl.getAddress();
  console.log("[2] Dashboard impl:", implAddress);

  const initData = Impl.interface.encodeFunctionData("initialize", [
    initialAdmin,
    CONET_USDC,
    CONET_GB,
    CONET_VDR,
    CONET_REFERRAL,
  ]);

  const Proxy = await ethers.getContractFactory("BeamioConsumerWalletDashboardProxy");
  const proxy = await Proxy.deploy(implAddress, initData);
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();
  console.log("[3] Dashboard proxy:", proxyAddress);

  const dash = Impl.attach(proxyAddress) as typeof impl;
  const ver = await dash.version();
  console.log("[4] version:", ver.toString());

  // Smoke: snapshot ZeroAddress should revert; use deployer as eoa
  try {
    const snap = await dash.snapshot(deployer.address, ethers.ZeroAddress);
    console.log("[5] snapshot smoke eoaNative:", snap.eoaNative.toString());
  } catch (e) {
    console.warn("[5] snapshot smoke failed (non-fatal):", e instanceof Error ? e.message : e);
  }

  const deployBlock = await ethers.provider.getBlockNumber();
  const dashOut = {
    network: "conet",
    chainId: "224422",
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    deployBlock,
    implementation: implAddress,
    proxy: proxyAddress,
    initializeArgs: {
      initialAdmin,
      usdc: CONET_USDC,
      gbToken: CONET_GB,
      validatorDepositRedeem: CONET_VDR,
      referralRegistry: CONET_REFERRAL,
    },
    Multicall3: multicallAddr,
    nextSteps: {
      syncSilentPassUI:
        "Set APP_DAEMON_CONET_MULTICALL3 + APP_DAEMON_WALLET_DASHBOARD in workers/appDaemon/protocol.ts",
      exportFull:
        "node scripts/exportStandardJsonFromBuildInfo.mjs BeamioConsumerWalletDashboard --full",
      verify: "Blockscout v2 standard-input (impl) + legacy partial (proxy)",
    },
  };
  fs.writeFileSync(DASH_OUT, JSON.stringify(dashOut, null, 2) + "\n", "utf-8");
  console.log("saved:", DASH_OUT);

  const addresses = loadAddressesJson();
  addresses.Multicall3 = multicallAddr;
  addresses.BeamioConsumerWalletDashboard = proxyAddress;
  addresses.BeamioConsumerWalletDashboardImpl = implAddress;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n", "utf-8");
  console.log("updated:", ADDRESSES_PATH);

  console.log("\nExplorer Multicall3:", `https://mainnet.conet.network/address/${multicallAddr}`);
  console.log("Explorer Dashboard:", `https://mainnet.conet.network/address/${proxyAddress}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
