/**
 * Deploy BeamioAgentReferrerRegistry (UUPS) on CoNET mainnet.
 *
 * CoNET only (chainId 224422). Canonical address = ERC1967 proxy.
 *
 * Offline EIP-712 writes (agent / temp / merchant / referrer). Gasless relayer
 * (x402sdk Master Settle_ConetPool) submits signed updates.
 *
 * Run:
 *   npm run compile
 *   npx hardhat run scripts/deployBeamioAgentReferrerRegistryConet.ts --network conet
 *
 * Env (optional):
 *   AGENT_REFERRER_INITIAL_ADMIN — initial admin (default deployer)
 *   DRY_RUN=1 — skip deploy
 *
 * After deploy: verify impl (v2 standard-input) + proxy (legacy partial) per
 *   conet-deploy-verify-on-the-spot.mdc / conet-mainnet-blockscout-verify.mdc
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const OUT_PATH = path.join(__dirname, "..", "deployments", "conet-BeamioAgentReferrerRegistry.json");

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

  const initialAdmin = process.env.AGENT_REFERRER_INITIAL_ADMIN || deployer.address;

  console.log("=".repeat(60));
  console.log("Deploy BeamioAgentReferrerRegistry (UUPS) on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("initialAdmin:", initialAdmin);
  const bal = await ethers.provider.getBalance(deployer.address);
  console.log("deployer CNET balance:", ethers.formatEther(bal));

  const Impl = await ethers.getContractFactory("BeamioAgentReferrerRegistry");
  const impl = await Impl.deploy();
  await impl.waitForDeployment();
  const implAddress = await impl.getAddress();
  console.log("[1] implementation:", implAddress);

  const initData = Impl.interface.encodeFunctionData("initialize", [initialAdmin]);

  const Proxy = await ethers.getContractFactory("BeamioAgentReferrerRegistryProxy");
  const proxy = await Proxy.deploy(implAddress, initData);
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();
  console.log("[2] proxy (canonical):", proxyAddress);

  const registry = Impl.attach(proxyAddress) as typeof impl;
  const ver = await registry.version();
  const isAdmin = await registry.admins(initialAdmin);
  const sep = await registry.domainSeparator();
  console.log("[3] version:", ver.toString(), "| admins[initialAdmin]:", isAdmin);
  console.log("    domainSeparator:", sep);

  const deployBlock = await ethers.provider.getBlockNumber();

  const out = {
    network: "conet",
    chainId: "224422",
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    deployBlock,
    implementation: implAddress,
    proxy: proxyAddress,
    initializeArgs: { initialAdmin },
    eip712: {
      name: "BeamioAgentReferrerRegistry",
      version: "1",
      chainId: 224422,
      verifyingContract: proxyAddress,
      types: {
        RegisterAgent: "RegisterAgent(address agent,uint256 nonce,uint256 deadline)",
        RegisterTemp: "RegisterTemp(address agent,address temp,uint256 nonce,uint256 deadline)",
        RegisterMerchant:
          "RegisterMerchant(address agent,address merchant,address temp,uint256 nonce,uint256 deadline)",
        RegisterReferrer:
          "RegisterReferrer(address introducer,address referee,uint256 nonce,uint256 deadline)",
      },
    },
    nextSteps: {
      exportFull:
        "node scripts/exportStandardJsonFromBuildInfo.mjs BeamioAgentReferrerRegistry --full",
      verify:
        "npx tsx scripts/verifyBeamioAgentReferrerRegistryConet.ts",
    },
  };

  fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
  fs.writeFileSync(OUT_PATH, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("saved:", OUT_PATH);

  const addresses = loadAddressesJson();
  addresses.BeamioAgentReferrerRegistry = proxyAddress;
  addresses.BeamioAgentReferrerRegistryImpl = implAddress;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n", "utf-8");
  console.log("updated:", ADDRESSES_PATH);

  console.log("\nExplorer proxy:", `https://mainnet.conet.network/address/${proxyAddress}`);
  console.log("Explorer impl:", `https://mainnet.conet.network/address/${implAddress}`);
  console.log("\nNext: npm run compile && node scripts/exportStandardJsonFromBuildInfo.mjs BeamioAgentReferrerRegistry --full");
  console.log("Then: npx tsx scripts/verifyBeamioAgentReferrerRegistryConet.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
