/**
 * 诊断 restoreWithUserPin 无法获取 beamioTag 信息
 * 从 CoNET 主链 AccountRegistry 拉取指定用户名的数据，排查问题
 *
 * 用法:
 *   BEAMIO_USER=rrrwe1111 npx tsx scripts/diagnoseRestoreWithUserPin.ts
 *   或
 *   npx tsx scripts/diagnoseRestoreWithUserPin.ts rrrwe1111
 */
import { ethers } from "ethers";
import * as path from "path";
import * as fs from "fs";

const CONET_RPC = process.env.CONET_RPC || "https://rpc1.conet.network";
const ACCOUNT_REGISTRY = "0x2dF9c4c51564FfF861965572CE11ebe27d3C1B35";

const AccountRegistryABI = [
  "function getBase64ByAccountName(string) view returns (string)",
  "function getBase64ByNameHash(bytes32) view returns (string)",
  "function getOwnerByAccountName(string) view returns (address)",
  "function getAccount(address) view returns (tuple(string accountName, string image, bool darkTheme, bool isUSDCFaucet, bool isETHFaucet, bool initialLoading, string firstName, string lastName, uint256 createdAt, bool exists))",
  "function isAccountNameAvailable(string) view returns (bool)",
  "function computeNameHash(string) view returns (bytes32)",
];

async function main() {
  const username =
    process.env.BEAMIO_USER ||
    process.argv.slice(2).find((a) => !a.startsWith("-")) ||
    "rrrwe1111";

  console.log("=".repeat(60));
  console.log("Diagnose restoreWithUserPin - CoNET AccountRegistry");
  console.log("=".repeat(60));
  console.log("Username:", username);
  console.log("RPC:", CONET_RPC);
  console.log("AccountRegistry:", ACCOUNT_REGISTRY);
  console.log();

  const provider = new ethers.JsonRpcProvider(CONET_RPC);
  const registry = new ethers.Contract(
    ACCOUNT_REGISTRY,
    AccountRegistryABI,
    provider
  );

  // 1. Check nameHash (same as contract uses)
  const nameHash = await registry.computeNameHash(username);
  console.log("[1] nameHash (keccak256):", nameHash);

  // 2. Check if account name is available (i.e. NOT taken = no owner)
  const isAvailable = await registry.isAccountNameAvailable(username);
  console.log("[2] isAccountNameAvailable:", isAvailable);
  if (isAvailable) {
    console.log("    -> Account name is NOT registered on CoNET (no owner)");
  }

  // 3. Get owner by account name
  let owner: string;
  try {
    owner = await registry.getOwnerByAccountName(username);
    console.log("[3] getOwnerByAccountName:", owner);
    if (owner === ethers.ZeroAddress) {
      console.log("    -> No owner (account not registered)");
    }
  } catch (e: any) {
    console.log("[3] getOwnerByAccountName: ERROR -", e?.message?.slice(0, 120));
    owner = ethers.ZeroAddress;
  }

  // 4. Get base64 recovery data by account name (what restoreWithUserPin uses)
  let base64Data: string;
  try {
    base64Data = await registry.getBase64ByAccountName(username);
    console.log("[4] getBase64ByAccountName length:", base64Data?.length ?? 0);
    if (!base64Data || base64Data.length === 0) {
      console.log("    -> EMPTY: No recovery data stored for this username");
      console.log("    -> restoreWithUserPin will fail (empty -> JSON.parse fails)");
    } else {
      console.log("    -> Has recovery data (first 80 chars):", base64Data.slice(0, 80) + "...");
    }
  } catch (e: any) {
    console.log("[4] getBase64ByAccountName: ERROR -", e?.message?.slice(0, 200));
    base64Data = "";
  }

  // 5. Also try getBase64ByNameHash (same hash)
  try {
    const base64ByHash = await registry.getBase64ByNameHash(nameHash);
    console.log("[5] getBase64ByNameHash length:", base64ByHash?.length ?? 0);
  } catch (e: any) {
    console.log("[5] getBase64ByNameHash: ERROR -", e?.message?.slice(0, 120));
  }

  // 6. If owner exists, get full account info (optional, ABI may differ from deployed contract)
  if (owner && owner !== ethers.ZeroAddress) {
    try {
      const acc = await registry.getAccount(owner);
      console.log("[6] getAccount(owner):");
      console.log("    accountName:", acc.accountName);
      console.log("    exists:", acc.exists);
      console.log("    createdAt:", acc.createdAt?.toString());
    } catch (e: any) {
      console.log("[6] getAccount: skip (ABI mismatch or not needed)");
    }
  }

  // 7. Try alternative formats (with/without @)
  const altNames = username.startsWith("@")
    ? [username.slice(1)]
    : [`@${username}`];
  if (altNames.length > 0) {
    console.log("\n[7] Alternative formats check:");
    for (const alt of altNames) {
      try {
        const altOwner = await registry.getOwnerByAccountName(alt);
        const altBase64 = await registry.getBase64ByAccountName(alt);
        console.log(`    "${alt}": owner=${altOwner !== ethers.ZeroAddress ? altOwner : "none"}, base64Len=${altBase64?.length ?? 0}`);
      } catch (_) {
        console.log(`    "${alt}": error`);
      }
    }
  }

  console.log("\n" + "=".repeat(60));
  console.log("Summary:");
  if (isAvailable || (!base64Data || base64Data.length === 0)) {
    console.log("  restoreWithUserPin fails because:");
    if (isAvailable) {
      console.log("    - Username is not registered on CoNET (no account)");
    }
    if (!base64Data || base64Data.length === 0) {
      console.log("    - No recovery base64 data stored for this username");
    }
    console.log("\n  Possible causes:");
    console.log("    1. User registered via beamio.app but recovery was never written to CoNET");
    console.log("    2. Different account name format (e.g. @rrrwe1111 vs rrrwe1111)");
    console.log("    3. User registered on a different chain/contract");
  } else {
    console.log("  Data exists on CoNET - restoreWithUserPin should work if PIN is correct");
  }
  console.log("=".repeat(60));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
