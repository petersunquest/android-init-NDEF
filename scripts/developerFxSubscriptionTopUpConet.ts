/**
 * Developer top-up helper (docs + optional dry read):
 *   USDC → prepaid FX ERC20 (e.g. TGB5) used as subscription inventory.
 *
 * Paths (already on CoNET):
 *  A) TreasuryBridgeV3.payAndMintWithSignature — EIP-3009 USDC pull + mint TGB5 to developer
 *  B) Acquire paid GB, then DeveloperTokenFxRegistry.burnGbMintDeveloper → treasury mints Canonical
 *
 * Settle: miner batchSettle with passTokenId=subscription NFT# burns **issuer** TGB5 for usage GB.
 *
 * Usage (read-only quotes):
 *   npx tsx scripts/developerFxSubscriptionTopUpConet.ts
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RPC = process.env.CONET_RPC_URL?.trim() || "https://rpc1.conet.network";
const ADDRESSES = path.join(__dirname, "..", "deployments", "conet-addresses.json");

async function main() {
  const addresses = JSON.parse(fs.readFileSync(ADDRESSES, "utf-8"));
  const tgb5 = addresses.TestDeveloperFxERC20 as string;
  const registry = addresses.DeveloperTokenFxRegistry as string;
  const settlement = addresses.DepinGbSettlement1155 as string;
  const passId = addresses.TGB5PayByUsePassTokenId || "5";
  const treasury = addresses.TreasuryBridgeV3 as string;

  const p = new ethers.JsonRpcProvider(RPC);
  const reg = new ethers.Contract(
    registry,
    [
      "function tokens(address) view returns (bool,bool,uint8,uint256,address)",
      "function quoteTokenIn(address,uint256) view returns (uint256)",
      "function quoteGbOut(address,uint256) view returns (uint256)",
    ],
    p,
  );
  const cfg = await reg.tokens(tgb5);
  const oneGb = 10n ** 9n;
  const tokenFor1Gb = await reg.quoteTokenIn(tgb5, oneGb);
  const gbFor1Token = await reg.quoteGbOut(tgb5, 10n ** 18n);

  console.log("=".repeat(60));
  console.log("Developer subscription prepaid (FX ERC20) — how to top up");
  console.log("=".repeat(60));
  console.log(`Settlement:     ${settlement}`);
  console.log(`FX Registry:    ${registry}`);
  console.log(`Treasury V3:    ${treasury}`);
  console.log(`FX ERC20 TGB5:  ${tgb5}`);
  console.log(`Subscription NFT#: ${passId}`);
  console.log(`Issuer (registry developer): ${cfg[4]}`);
  console.log(`Rate: 1 full token → ${ethers.formatUnits(gbFor1Token, 9)} GB`);
  console.log(`Settle 1 GB burns ≈ ${ethers.formatEther(tokenFor1Gb)} TGB5 from **issuer**`);
  console.log("");
  console.log("Top-up options:");
  console.log("  A) Offline payAndMint USDC→TGB5 (TreasuryBridgeV3) — see");
  console.log("     scripts/upgradeTreasuryOfflineSignAndPayMintConet.ts");
  console.log("  B) Hold paid GB, then registry.burnGbMintDeveloper(issuer, TGB5, gbAmount)");
  console.log("");
  console.log("Issue subscription to users:");
  console.log(`  settlement.mintPass(user, ${passId}, amount)  // caller = issuer or admin`);
  console.log("");
  console.log("Miner settle (customer not charged GB):");
  console.log(`  batchSettle([{ user, amountGb, guardianNodeId|toAdmin, passTokenId: ${passId}, ... }])`);
  console.log("  → burns issuer TGB5, mints GB to miner beneficiary");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
