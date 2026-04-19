/**
 * Check if BUnitAirdrop is admin of BUint (required for consumeFromUser/consumeFuel)
 * Run: npx tsx scripts/checkBUnitAirdropBUintAdmin.ts
 */
import { ethers } from "ethers";

const BUINT = "0x4A3E59519eE72B9Dcf376f0617fF0a0a5a1ef879";
const BUNIT_AIRDROP = "0xbE1CF54f76BcAb40DC49cDcD7FBA525b9ABDa264";
const RPC = process.env.CONET_RPC || "https://rpc1.conet.network";

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const buint = new ethers.Contract(BUINT, ["function admins(address) view returns (bool)"], provider);
  const isAdmin = await buint.admins(BUNIT_AIRDROP);
  console.log("BUint:", BUINT);
  console.log("BUnitAirdrop:", BUNIT_AIRDROP);
  console.log("BUnitAirdrop is BUint admin:", isAdmin);
}

main().catch(console.error);
