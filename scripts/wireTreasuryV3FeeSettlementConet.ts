/**
 * Wire V3 as unique conet-USDC for B-Unit fee mint:
 *   1) grant TREASURY_ROLE on V3 USDC to BridgeV3
 *   2) BridgeV3.setFeeSettlement(BUnitAirdrop, V3 USDC)
 *   3) BUnitAirdrop.setConetTreasuryAndUsdc(BridgeV3, V3 USDC)
 *
 * Usage:
 *   npx hardhat run scripts/wireTreasuryV3FeeSettlementConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

const BRIDGE = "0xa208982212978550594A7FEEB70a61665d129003";
const V3_USDC = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";
const BUNIT_AIRDROP = "0x305f90A7f38289219BA1b4be98CB5b47e7b15Ac2";
const FACTORY_USDC_LEGACY = "0xfD0D7B0706AaB5E4351bcED37bC3C77ed6813907";

async function main() {
  const { ethers } = await networkModule.connect();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  if (chainId !== 224422) {
    throw new Error(`Expected CoNET 224422, got ${chainId}`);
  }

  const signers = await ethers.getSigners();
  const signer = signers[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);

  const usdc = new ethers.Contract(
    V3_USDC,
    [
      "function DEFAULT_ADMIN_ROLE() view returns (bytes32)",
      "function TREASURY_ROLE() view returns (bytes32)",
      "function hasRole(bytes32,address) view returns (bool)",
      "function grantRole(bytes32,address)",
      "function setTreasury(address)",
    ],
    signer,
  );

  const bridge = new ethers.Contract(
    BRIDGE,
    [
      "function owner() view returns (address)",
      "function setFeeSettlement(address settlement, address asset)",
      "function feeSettlement() view returns (address)",
      "function feeSettlementAsset() view returns (address)",
    ],
    signer,
  );

  const airdrop = new ethers.Contract(
    BUNIT_AIRDROP,
    [
      "function owner() view returns (address)",
      "function conetTreasury() view returns (address)",
      "function conetUsdc() view returns (address)",
      "function setConetTreasuryAndUsdc(address _conetTreasury, address _conetUsdc)",
    ],
    signer,
  );

  const adminRole = await usdc.DEFAULT_ADMIN_ROLE();
  if (!(await usdc.hasRole(adminRole, signer.address))) {
    throw new Error(`Signer ${signer.address} is not V3 USDC admin`);
  }
  const bridgeOwner = await bridge.owner();
  if (bridgeOwner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer ${signer.address} is not Bridge owner ${bridgeOwner}`);
  }
  const airdropOwner = await airdrop.owner();
  if (airdropOwner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer ${signer.address} is not Airdrop owner ${airdropOwner}`);
  }

  const treasuryRole = await usdc.TREASURY_ROLE();
  let grantTxHash: string | null = null;
  if (!(await usdc.hasRole(treasuryRole, BRIDGE))) {
    const tx = await usdc.setTreasury(BRIDGE);
    await tx.wait();
    grantTxHash = tx.hash;
  }

  let feeTxHash: string | null = null;
  const currentSettlement = await bridge.feeSettlement();
  const currentAsset = await bridge.feeSettlementAsset();
  if (
    currentSettlement.toLowerCase() !== BUNIT_AIRDROP.toLowerCase()
    || currentAsset.toLowerCase() !== V3_USDC.toLowerCase()
  ) {
    const tx = await bridge.setFeeSettlement(BUNIT_AIRDROP, V3_USDC);
    await tx.wait();
    feeTxHash = tx.hash;
  }

  let airdropTxHash: string | null = null;
  const curTreasury = await airdrop.conetTreasury();
  const curUsdc = await airdrop.conetUsdc();
  if (
    curTreasury.toLowerCase() !== BRIDGE.toLowerCase()
    || curUsdc.toLowerCase() !== V3_USDC.toLowerCase()
  ) {
    const tx = await airdrop.setConetTreasuryAndUsdc(BRIDGE, V3_USDC);
    await tx.wait();
    airdropTxHash = tx.hash;
  }

  // Probe legacy factory USDC minter (stop-mint is best-effort; may lack setter)
  let legacyMinter: string | null = null;
  let legacyMinterNote = "probe only";
  try {
    const legacy = new ethers.Contract(
      FACTORY_USDC_LEGACY,
      ["function minter() view returns (address)"],
      ethers.provider,
    );
    legacyMinter = await legacy.minter();
    legacyMinterNote =
      "Factory USDC still has a minter; revoke via ConetTreasury/miner path if product requires hard stop";
  } catch {
    legacyMinterNote = "Could not read legacy factory minter()";
  }

  const out = {
    chainId,
    bridge: BRIDGE,
    v3Usdc: V3_USDC,
    bunitAirdrop: BUNIT_AIRDROP,
    grantTxHash,
    feeTxHash,
    airdropTxHash,
    feeSettlement: await bridge.feeSettlement(),
    feeSettlementAsset: await bridge.feeSettlementAsset(),
    airdropTreasury: await airdrop.conetTreasury(),
    airdropUsdc: await airdrop.conetUsdc(),
    bridgeHasTreasuryRole: await usdc.hasRole(treasuryRole, BRIDGE),
    factoryUsdcLegacy: FACTORY_USDC_LEGACY,
    legacyMinter,
    legacyMinterNote,
    wiredAt: new Date().toISOString(),
  };

  const outPath = path.join(ROOT, "deployments", "conet-treasury-v3-fee-settlement-wire.json");
  fs.writeFileSync(outPath, `${JSON.stringify(out, null, 2)}\n`);
  console.log(JSON.stringify(out, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
