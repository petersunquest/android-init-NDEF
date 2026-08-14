/**
 * Deploy DepinGbSettlement1155 (UUPS) on CoNET mainnet and wire GBToken admin.
 *
 * CoNET only (chainId 224422). Canonical address = ERC1967 proxy.
 *
 * Run:
 *   npm run compile
 *   npx hardhat run scripts/deployDepinGbSettlement1155Conet.ts --network conet
 *
 * Env (optional):
 *   GB_TOKEN_ERC20 — GBToken proxy (default 0xC3EF…38D8)
 *   VDR_ADDRESS — ValidatorDepositRedeem proxy
 *   MIN_BOND_WEI — settler CNET bond floor (default 1 ether)
 *   UNBOND_DELAY — seconds (default 7 days)
 *   METADATA_URI — ERC-1155 uri template (default https://beamio.app/api/metadata/depin-settle/{id}.json)
 *   SKIP_GB_ADMIN=1 — do not call GBToken.addAdmin(proxy)
 *   DRY_RUN=1 — compile path check only (no deploy)
 *
 * After deploy: verify impl + proxy per conet-deploy-verify-on-the-spot.mdc
 *   node scripts/exportStandardJsonFromBuildInfo.mjs DepinGbSettlement1155 --full
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const MASTER_PATH = path.join(homedir(), ".master.json");
const OUT_PATH = path.join(__dirname, "..", "deployments", "conet-DepinGbSettlement1155.json");

const DEFAULT_GB_TOKEN = "0xC3EF02DaE632b4C10abB66e07d92a387c10838D8";
const DEFAULT_VDR = "0xc71e246DD78B37C2fABc905D340932F28F503433";
const DEFAULT_MIN_BOND_WEI = 10n ** 18n; // 1 CNET
const DEFAULT_UNBOND_DELAY = 7n * 24n * 60n * 60n; // 7 days
const DEFAULT_URI = "https://beamio.app/api/metadata/depin-settle/{id}.json";

function loadAddressesJson(): Record<string, unknown> {
  if (!fs.existsSync(ADDRESSES_PATH)) return {};
  return JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
}

function loadSettleAdmins(): string[] {
  if (!fs.existsSync(MASTER_PATH)) return [];
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const arr = data?.settle_contractAdmin || [];
  return arr.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`));
}

async function main() {
  if (process.env.DRY_RUN === "1") {
    console.log("DRY_RUN=1 — skip deploy");
    return;
  }

  const addrJson = loadAddressesJson();
  const gbToken =
    process.env.GB_TOKEN_ERC20 ||
    (addrJson.GBToken as string) ||
    (addrJson.contracts as { gbErc20?: { address?: string } })?.gbErc20?.address ||
    DEFAULT_GB_TOKEN;
  const vdr =
    process.env.VDR_ADDRESS || (addrJson.ValidatorDepositRedeem as string) || DEFAULT_VDR;
  const minBondWei = process.env.MIN_BOND_WEI
    ? BigInt(process.env.MIN_BOND_WEI)
    : DEFAULT_MIN_BOND_WEI;
  const unbondDelay = process.env.UNBOND_DELAY
    ? BigInt(process.env.UNBOND_DELAY)
    : DEFAULT_UNBOND_DELAY;
  const uri = process.env.METADATA_URI || DEFAULT_URI;

  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`Expected CoNET chainId 224422, got ${net.chainId}`);
  }

  console.log("=".repeat(60));
  console.log("Deploy DepinGbSettlement1155 (UUPS) on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("GBToken:", gbToken);
  console.log("ValidatorDepositRedeem:", vdr);
  console.log("minBondWei:", minBondWei.toString());
  console.log("unbondDelay:", unbondDelay.toString());
  console.log("uri:", uri);

  const Impl = await ethers.getContractFactory("DepinGbSettlement1155");
  const impl = await Impl.deploy();
  await impl.waitForDeployment();
  const implAddress = await impl.getAddress();
  console.log("[1] implementation:", implAddress);

  const initData = Impl.interface.encodeFunctionData("initialize", [
    deployer.address,
    gbToken,
    vdr,
    uri,
    minBondWei,
    unbondDelay,
  ]);

  const Proxy = await ethers.getContractFactory("DepinGbSettlement1155Proxy");
  const proxy = await Proxy.deploy(implAddress, initData);
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();
  console.log("[2] proxy (canonical):", proxyAddress);

  const settlement = Impl.attach(proxyAddress);

  if (process.env.SKIP_GB_ADMIN !== "1") {
    const gb = await ethers.getContractAt("GBTokenV2", gbToken);
    if (!gb.interface.getFunction("consumeGb")) {
      throw new Error("GBToken proxy is not V2 (missing consumeGb)");
    }
    const txAdmin = await gb.addAdmin(proxyAddress);
    await txAdmin.wait();
    console.log("[3] GBToken.addAdmin(settlement proxy) ok");
  } else {
    console.log("[3] SKIP_GB_ADMIN=1 — remember to addAdmin(proxy) manually");
  }

  const settlePks = loadSettleAdmins();
  for (const pk of settlePks) {
    const addr = new ethers.Wallet(pk).address;
    if (addr.toLowerCase() === deployer.address.toLowerCase()) continue;
    const tx = await settlement.addAdmin(addr);
    await tx.wait();
    console.log("[4] settlement.addAdmin(", addr, ") ok");
  }

  const out = {
    network: "conet",
    chainId: "224422",
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    implementation: implAddress,
    proxy: proxyAddress,
    initializeArgs: {
      initialAdmin: deployer.address,
      gbToken,
      validatorDepositRedeem: vdr,
      uri,
      minBondWei: minBondWei.toString(),
      unbondDelay: unbondDelay.toString(),
    },
    nextSteps: {
      exportFull:
        "node scripts/exportStandardJsonFromBuildInfo.mjs DepinGbSettlement1155 --full",
      verifyNote:
        "Verify implementation via Blockscout v2 standard-input; proxy via legacy partial (OZ ERC1967).",
      settlerBond: "Nodes call bondDeposit{value: minBondWei} on proxy before batchSettle",
      deprecateCharge: "Stop new callers of GBDepinAirdrop.chargeUserGbForGuardianNode",
    },
  };

  fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
  fs.writeFileSync(OUT_PATH, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("saved:", OUT_PATH);

  // Mirror into conet-addresses.json
  const addresses = loadAddressesJson();
  addresses.DepinGbSettlement1155 = proxyAddress;
  addresses.DepinGbSettlement1155Impl = implAddress;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n", "utf-8");
  console.log("updated:", ADDRESSES_PATH);

  console.log("\nExplorer proxy:", `https://mainnet.conet.network/address/${proxyAddress}`);
  console.log("Explorer impl:", `https://mainnet.conet.network/address/${implAddress}`);
  console.log("\nNext:");
  console.log("  npm run clean && npm run compile");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs DepinGbSettlement1155 --full");
  console.log("  (then Blockscout verify impl + proxy — conet-deploy-verify-on-the-spot.mdc)");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
