/**
 * Wire live BUnitAirdrop proxy storage to BridgeV3 + V3 USDC via temporary UUPS impl,
 * then restore the production implementation.
 *
 * Live Airdrop `0x305f…` is UUPS; production impl lacks `setConetTreasuryAndUsdc`.
 *
 * Usage:
 *   npx hardhat run scripts/wireBUnitAirdropTreasuryViaTempUpgradeConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

const AIRDROP_PROXY = "0x305f90A7f38289219BA1b4be98CB5b47e7b15Ac2";
const PRODUCTION_IMPL = "0xD402b631F5171427FB2e04c4C975bb7d9b807504";
const BRIDGE = "0xa208982212978550594A7FEEB70a61665d129003";
const V3_USDC = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";
const IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

async function main() {
  const { ethers } = await networkModule.connect();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  if (chainId !== 224422) {
    throw new Error(`Expected CoNET 224422, got ${chainId}`);
  }

  const signers = await ethers.getSigners();
  const signer = signers[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);

  const proxy = new ethers.Contract(
    AIRDROP_PROXY,
    [
      "function owner() view returns (address)",
      "function conetTreasury() view returns (address)",
      "function conetUsdc() view returns (address)",
      "function upgradeToAndCall(address newImplementation, bytes data) payable",
    ],
    signer,
  );

  const owner = await proxy.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer ${signer.address} is not Airdrop owner ${owner}`);
  }

  const before = {
    treasury: await proxy.conetTreasury(),
    usdc: await proxy.conetUsdc(),
  };

  const factory = await ethers.getContractFactory("BUnitAirdropV2TreasuryWire", signer);
  const wireImpl = await factory.deploy();
  await wireImpl.waitForDeployment();
  const wireAddress = await wireImpl.getAddress();
  const deployTx = wireImpl.deploymentTransaction();
  if (!deployTx) throw new Error("wire impl deploy tx missing");
  await deployTx.wait();

  const setData = wireImpl.interface.encodeFunctionData("setConetTreasuryAndUsdc", [
    BRIDGE,
    V3_USDC,
  ]);

  const upgradeSetTx = await proxy.upgradeToAndCall(wireAddress, setData);
  await upgradeSetTx.wait();

  const midTreasury = await proxy.conetTreasury();
  const midUsdc = await proxy.conetUsdc();
  if (
    midTreasury.toLowerCase() !== BRIDGE.toLowerCase()
    || midUsdc.toLowerCase() !== V3_USDC.toLowerCase()
  ) {
    throw new Error(`Wire set failed: treasury=${midTreasury} usdc=${midUsdc}`);
  }

  const restoreTx = await proxy.upgradeToAndCall(PRODUCTION_IMPL, "0x");
  await restoreTx.wait();

  const rawSlot = await ethers.provider.getStorage(AIRDROP_PROXY, IMPLEMENTATION_SLOT);
  const actualImpl = ethers.getAddress(`0x${rawSlot.slice(-40)}`);
  if (actualImpl.toLowerCase() !== PRODUCTION_IMPL.toLowerCase()) {
    throw new Error(`Restore failed: impl=${actualImpl}`);
  }

  const after = {
    treasury: await proxy.conetTreasury(),
    usdc: await proxy.conetUsdc(),
  };

  const out = {
    chainId,
    airdropProxy: AIRDROP_PROXY,
    wireImplementation: wireAddress,
    wireDeployTx: deployTx.hash,
    upgradeSetTx: upgradeSetTx.hash,
    restoreTx: restoreTx.hash,
    productionImpl: PRODUCTION_IMPL,
    before,
    after,
    wiredAt: new Date().toISOString(),
  };
  const outPath = path.join(ROOT, "deployments", "conet-bunit-airdrop-v3-usdc-wire.json");
  fs.writeFileSync(outPath, `${JSON.stringify(out, null, 2)}\n`);
  console.log(JSON.stringify(out, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
