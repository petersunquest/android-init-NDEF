/**
 * UUPS upgrade GenesisNodeReferralVaultV1 impl on CoNET (same proxy).
 *
 *   npx hardhat run scripts/upgradeGenesisNodeReferralVaultConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const DEPLOY_PATH = path.join(ROOT, "deployments", "conet-genesis-node-referral-vault.json");

async function main() {
  const { ethers } = await networkModule.connect();
  const network = await ethers.provider.getNetwork();
  if (Number(network.chainId) !== 224422) {
    throw new Error(`Upgrade on CoNET only, got ${network.chainId}`);
  }

  if (!fs.existsSync(DEPLOY_PATH)) throw new Error(`Missing ${DEPLOY_PATH}`);
  const prev = JSON.parse(fs.readFileSync(DEPLOY_PATH, "utf8")) as {
    contracts?: { GenesisNodeReferralVaultV1Proxy?: string };
  };
  const proxyAddr = prev.contracts?.GenesisNodeReferralVaultV1Proxy;
  if (!proxyAddr) throw new Error("Missing proxy address in deployment JSON");

  const signers = await ethers.getSigners();
  const signer = signers[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);

  const factory = await ethers.getContractFactory("GenesisNodeReferralVaultV1", signer);
  const implementation = await factory.deploy();
  await implementation.waitForDeployment();
  const implAddr = await implementation.getAddress();
  const implTx = implementation.deploymentTransaction();
  if (!implTx) throw new Error("missing impl tx");
  const implReceipt = await implTx.wait();

  const proxy = await ethers.getContractAt("GenesisNodeReferralVaultV1", proxyAddr, signer);
  const upgradeTx = await proxy.upgradeToAndCall(implAddr, "0x");
  const upgradeReceipt = await upgradeTx.wait();

  // Smoke: new L1 views exist
  const l1Count = await proxy.l1Count();
  console.log(`l1Count after upgrade: ${l1Count}`);

  const out = {
    ...prev,
    contracts: {
      ...prev.contracts,
      GenesisNodeReferralVaultV1Implementation: implAddr,
      GenesisNodeReferralVaultV1Proxy: proxyAddr,
    },
    upgrade: {
      previousImplNote: "see git history / prior JSON",
      newImplementation: implAddr,
      upgradeTx: upgradeTx.hash,
      upgradeBlock: upgradeReceipt?.blockNumber,
      implDeployTx: implTx.hash,
      implDeployBlock: implReceipt?.blockNumber,
      features: "L1 redeem + ratioBps; bindSale referrer must be L1",
      upgradedAt: new Date().toISOString(),
    },
  };
  fs.writeFileSync(DEPLOY_PATH, `${JSON.stringify(out, null, 2)}\n`);
  console.log(JSON.stringify(out, null, 2));
  console.log(`\nWrote ${DEPLOY_PATH}`);
  console.log("Next: VERIFY_CHAIN=conet npx tsx scripts/verifyGenesisNodeReferralVaultOnScan.ts");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
