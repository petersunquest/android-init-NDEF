/**
 * Check BUnit balance for an account on CoNET
 * Run: USER=0x... npx hardhat run scripts/checkBUnitBalance.ts --network conet
 */
import { ethers } from "ethers";

const BUNIT_AIRDROP = "0xFd60936707cb4583c08D8AacBA19E4bfaEE446B8";
const CONET_RPC = process.env.CONET_RPC || "https://rpc1.conet.network";

async function main() {
  const userAddr = process.env.CHECK_USER || process.env.USER_ADDR || "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
  const user = userAddr.startsWith("0x") && userAddr.length === 42 ? userAddr : "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
  const provider = new ethers.JsonRpcProvider(CONET_RPC);
  const airdrop = new ethers.Contract(
    BUNIT_AIRDROP,
    ["function getBUnitBalance(address) view returns (uint256)"],
    provider
  );
  const bal = await airdrop.getBUnitBalance(user);
  console.log("Account:", user);
  console.log("BUnit balance (raw):", bal.toString());
  console.log("BUnit balance (human):", ethers.formatUnits(bal, 6), "B-Units");
}

main().catch(console.error);
