/**
 * Deploy BeamioMyBrandsDashboard (UUPS) on CoNET for SilentPassUI My Brands.
 *
 * Run from BeamioContract root:
 *   npm run compile
 *   npx hardhat run scripts/deployBeamioMyBrandsDashboardConet.ts --network conet
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
const DASH_OUT = path.join(__dirname, "..", "deployments", "conet-BeamioMyBrandsDashboard.json");

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
  console.log("Deploy BeamioMyBrandsDashboard on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  const initialAdmin = process.env.DASHBOARD_INITIAL_ADMIN || deployer.address;
  const Impl = await ethers.getContractFactory("BeamioMyBrandsDashboard");
  const impl = await Impl.deploy();
  await impl.waitForDeployment();
  const implAddress = await impl.getAddress();
  console.log("[1] MyBrandsDashboard impl:", implAddress);

  const initData = Impl.interface.encodeFunctionData("initialize", [initialAdmin]);

  const Proxy = await ethers.getContractFactory("BeamioMyBrandsDashboardProxy");
  const proxy = await Proxy.deploy(implAddress, initData);
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();
  console.log("[2] MyBrandsDashboard proxy:", proxyAddress);

  const dash = Impl.attach(proxyAddress) as typeof impl;
  const ver = await dash.version();
  console.log("[3] version:", ver.toString());

  // Smoke: empty cards array
  try {
    const empty = await dash.snapshotCards([], deployer.address, ethers.ZeroAddress, 2n);
    console.log("[4] snapshotCards([]) length:", empty.length);
  } catch (e) {
    console.warn("[4] snapshotCards smoke failed:", e instanceof Error ? e.message : e);
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
    },
    nextSteps: {
      syncSilentPassUI:
        "Set CONET_MY_BRANDS_DASHBOARD in SilentPassUI config/chainAddresses.ts + utils/myBrandsDashboard.ts",
      exportFull: "node scripts/exportStandardJsonFromBuildInfo.mjs BeamioMyBrandsDashboard --full",
      verify: "npx tsx scripts/verifyBeamioMyBrandsDashboardConet.ts",
    },
  };
  fs.mkdirSync(path.dirname(DASH_OUT), { recursive: true });
  fs.writeFileSync(DASH_OUT, JSON.stringify(dashOut, null, 2) + "\n", "utf-8");
  console.log("saved:", DASH_OUT);

  const addresses = loadAddressesJson();
  addresses.BeamioMyBrandsDashboard = proxyAddress;
  addresses.BeamioMyBrandsDashboardImpl = implAddress;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n", "utf-8");
  console.log("updated:", ADDRESSES_PATH);

  console.log("\nExplorer:", `https://mainnet.conet.network/address/${proxyAddress}`);
  console.log("Impl:", `https://mainnet.conet.network/address/${implAddress}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
