/**
 * Deploy GenesisNodeReferralVaultV1 UUPS proxy on CoNET and allowlist on Treasury V3.
 *
 *   npx hardhat run scripts/deployGenesisNodeReferralVaultConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const TREASURY = "0xa208982212978550594A7FEEB70a61665d129003";
const CONET_USDC = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";

async function main() {
  const { ethers } = await networkModule.connect();
  const network = await ethers.provider.getNetwork();
  if (Number(network.chainId) !== 224422) {
    throw new Error(`Genesis referral vault deploys on CoNET only, got ${network.chainId}`);
  }

  const signers = await ethers.getSigners();
  const signer = signers[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);
  const owner = signer.address;
  // Bridge binder / LockMint initiator = same settle admin that Master uses.
  const bridgeBinder = owner;
  const foundation = owner;
  const defaultAdminPayout = owner;

  const factory = await ethers.getContractFactory("GenesisNodeReferralVaultV1", signer);
  const implementation = await factory.deploy();
  await implementation.waitForDeployment();
  const implAddr = await implementation.getAddress();
  const implTx = implementation.deploymentTransaction();
  if (!implTx) throw new Error("missing impl tx");
  await implTx.wait();

  const initData = factory.interface.encodeFunctionData("initialize", [
    owner,
    TREASURY,
    CONET_USDC,
    foundation,
    defaultAdminPayout,
    bridgeBinder,
  ]);
  const proxyFactory = await ethers.getContractFactory("TreasuryV3ERC1967Proxy", signer);
  const proxy = await proxyFactory.deploy(implAddr, initData);
  await proxy.waitForDeployment();
  const proxyAddr = await proxy.getAddress();
  const proxyTx = proxy.deploymentTransaction();
  if (!proxyTx) throw new Error("missing proxy tx");
  const proxyReceipt = await proxyTx.wait();

  const treasury = new ethers.Contract(
    TREASURY,
    [
      "function owner() view returns (address)",
      "function setMintCallbackAllowed(address target, bool allowed)",
      "function allowedMintCallbacks(address) view returns (bool)",
    ],
    signer,
  );
  const treasuryOwner = await treasury.owner();
  if (treasuryOwner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer ${signer.address} is not Treasury owner ${treasuryOwner}`);
  }
  const allowTx = await treasury.setMintCallbackAllowed(proxyAddr, true);
  const allowReceipt = await allowTx.wait();
  const allowed = await treasury.allowedMintCallbacks(proxyAddr);
  if (!allowed) throw new Error("setMintCallbackAllowed failed");

  const out = {
    network: "conet",
    chainId: 224422,
    deployer: owner,
    contracts: {
      GenesisNodeReferralVaultV1Implementation: implAddr,
      GenesisNodeReferralVaultV1Proxy: proxyAddr,
      treasury: TREASURY,
      conetUsdc: CONET_USDC,
    },
    initialize: {
      owner,
      treasury: TREASURY,
      conetUsdc: CONET_USDC,
      foundation,
      defaultAdminPayout,
      bridgeBinder,
    },
    transactions: {
      implementation: implTx.hash,
      proxy: proxyTx.hash,
      proxyBlock: proxyReceipt?.blockNumber,
      setMintCallbackAllowed: allowTx.hash,
      setMintCallbackAllowedBlock: allowReceipt?.blockNumber,
    },
    mintCallback: {
      allowed: true,
      note: "Treasury setMintCallbackAllowed(vault, true) — LockMint callbackTarget must be this proxy",
    },
    createdAt: new Date().toISOString(),
  };

  const deploymentPath = path.join(ROOT, "deployments", "conet-genesis-node-referral-vault.json");
  fs.writeFileSync(deploymentPath, `${JSON.stringify(out, null, 2)}\n`);
  console.log(JSON.stringify(out, null, 2));
  console.log(`\nWrote ${deploymentPath}`);
  console.log("Next: VERIFY_CHAIN=conet npx tsx scripts/verifyGenesisNodeReferralVaultOnScan.ts");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
