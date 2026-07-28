/**
 * Read-only verification preflight. It never submits a deployment or
 * verification transaction. For CoNET it enforces code presence and prints
 * the required FULL Standard JSON workflow; for Base it prints the Token Info
 * preparation command.
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

async function main() {
  const { ethers } = await networkModule.connect();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const prefix = chainId === 8453 ? "base" : "conet";
  const treasury = JSON.parse(
    fs.readFileSync(path.join(ROOT, "deployments", `${prefix}-treasury-v3.json`), "utf8"),
  );
  const assets = JSON.parse(
    fs.readFileSync(path.join(ROOT, "deployments", `${prefix}-treasury-v3-assets.json`), "utf8"),
  );
  const addresses = [
    treasury.contracts.TreasuryBridgeV3Implementation,
    treasury.contracts.TreasuryBridgeV3Proxy,
    ...Object.values(assets.assets).flatMap((asset: any) => [asset.implementation, asset.proxy]),
  ];
  for (const address of addresses) {
    const code = await ethers.provider.getCode(address);
    if (code === "0x") throw new Error(`No deployed bytecode at ${address}`);
    console.log(`${address} code=${(code.length - 2) / 2} bytes`);
  }
  if (chainId === 224422) {
    console.log("CoNET verification workflow:");
    console.log("  npm run clean && npm run compile");
    console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs TreasuryBridgeV3 --full");
    console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs TreasuryCanonicalERC20V3 --full");
    console.log("  npm run export:treasury-v3-verify-form");
    console.log("  compare each deployedBytecode with eth_getCode before Blockscout v2 submission");
  } else {
    console.log("Base verification workflow:");
    console.log("  npm run clean && npm run compile");
    console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs TreasuryBridgeV3 --full");
    console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs TreasuryCanonicalERC20V3 --full");
    console.log("  npm run export:treasury-v3-verify-form");
    console.log("  npm run prepare:basescan:treasury-v3-token-info");
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
