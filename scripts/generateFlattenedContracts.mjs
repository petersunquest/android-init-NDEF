#!/usr/bin/env node
/**
 * Generate clean flattened contract files for BaseScan Solidity (Single File) verification.
 * This is the ultimate fallback for CREATE2/Nick's Factory deployments on BaseScan,
 * where BaseScan lacks creation bytecode in its database (causing standard-json auto-match to fail).
 */

import fs from "fs";
import path from "path";
import { execSync } from "child_process";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const flattenedDir = path.join(root, "deployments/flattened");

if (!fs.existsSync(flattenedDir)) {
  fs.mkdirSync(flattenedDir, { recursive: true });
}

const bundlePath = path.join(root, "deployments/base-ConetTreasuryStack-verify-bundle.json");
if (!fs.existsSync(bundlePath)) {
  throw new Error("Missing deployments/base-ConetTreasuryStack-verify-bundle.json.");
}

const bundle = JSON.parse(fs.readFileSync(bundlePath, "utf-8"));

const guide = [
  "==============================================================",
  "BaseScan UI Verification Guide (Solidity Single File Method)",
  "==============================================================",
  "For CREATE2 contracts deployed via Nick's Factory, BaseScan's",
  "database often has empty indexed creation bytecode (the blank row).",
  "Standard-Json verification fails because it cannot auto-detect.",
  "",
  "The 100% working solution is to verify using the 'Solidity (Single File)'",
  "method in the UI. This allows you to type the Contract Name explicitly,",
  "which forces BaseScan to compile your target and match runtime bytecode.",
  "",
  "Steps for each contract on BaseScan:",
  "1. Go to https://basescan.org/address/<CONTRACT_ADDRESS>#code",
  "2. Click 'Verify and Publish'",
  "3. Select:",
  "   - Compiler Type: Solidity (Single File)",
  "   - Compiler Version: v0.8.33+commit.64118f21",
  "   - License Type: MIT (or No License/MIT accordingly)",
  "4. On the next page, fill in:",
  "   - Contract Name: <CONTRACT_NAME> (e.g. ConetTreasury, ConetTreasuryPeer, etc.)",
  "   - Optimization: Yes, runs: 0",
  "   - Solidity Contract Code: Copy & paste the contents of the flattened file",
  "   - Constructor Arguments (ABI-encoded): <CONSTRUCTOR_ARGS>",
  "5. Click 'Verify and Publish'",
  "",
  "--------------------------------------------------------------",
];

for (const item of bundle.contracts ?? []) {
  const lastColon = item.contractName.lastIndexOf(":");
  const sourceKey = item.contractName.slice(0, lastColon);
  const contractName = item.contractName.slice(lastColon + 1);

  // Source path from root
  const sourcePathRel = sourceKey.replace(/^project\//, "");
  const fullSourcePath = path.join(root, sourcePathRel);

  console.log(`Flattening ${item.exportKey} (${sourcePathRel}) ...`);

  // Run hardhat flatten
  let flatSource = "";
  try {
    flatSource = execSync(`npx hardhat flatten "${fullSourcePath}" 2>/dev/null`, {
      cwd: root,
      encoding: "utf-8",
    });
  } catch (err) {
    console.error(`Failed to flatten ${item.exportKey}:`, err.message);
    continue;
  }

  // Clean dotenv injector noise if any
  flatSource = flatSource.replace(/^\[dotenv[^\n]*\n/, "");
  // Clean secondary occurrences just in case
  flatSource = flatSource.replace(/\n\[dotenv[^\n]*\n/g, "\n");

  // Keep a clean single SPDX license and pragma at the top of the file
  // Etherscan accepts multiple pragmas/licenses if they are commented, but it is much cleaner to normalize.
  // We'll leave the hardhat-flattened code intact but verify that the dotenv line is stripped.

  const outRel = `deployments/flattened/base-${item.exportKey}-flat.sol`;
  const outPath = path.join(root, outRel);
  fs.writeFileSync(outPath, flatSource, "utf-8");

  console.log(`  Saved to: ${outRel}`);

  guide.push(
    `## ${item.exportKey}`,
    `Contract Address: ${item.address}`,
    `Contract Name   : ${contractName}`,
    `Flattened File  : ${outRel}`,
    `Constructor Args: ${String(item.constructorArgs ?? "").replace(/^0x/, "") || "(none)"}`,
    ""
  );
}

const guidePath = path.join(root, "deployments/flattened/basescan-flat-verify-guide.txt");
fs.writeFileSync(guidePath, guide.join("\n"), "utf-8");
console.log(`\nGuide saved to: ${guidePath}`);
