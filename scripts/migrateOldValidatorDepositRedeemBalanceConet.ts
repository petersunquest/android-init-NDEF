/**
 * Transfer native CNET balance from deprecated ValidatorDepositRedeem to the current deployment.
 *
 * Usage:
 *   npx hardhat run scripts/migrateOldValidatorDepositRedeemBalanceConet.ts --network conet
 *
 * Env (optional):
 *   OLD_VALIDATOR_DEPOSIT_REDEEM=0x970792…  (default: last deprecated address)
 *   NEW_VALIDATOR_DEPOSIT_REDEEM=…          (default: deployments/conet-addresses.json)
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_OLD = "0x02C425537E3E2C7B9F3071DdFc4E0d81DD3B2EFC";

async function main() {
  const addressesPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  const addrData = JSON.parse(fs.readFileSync(addressesPath, "utf-8")) as {
    ValidatorDepositRedeem?: string;
  };
  const newAddr = (process.env.NEW_VALIDATOR_DEPOSIT_REDEEM || addrData.ValidatorDepositRedeem || "").trim();
  const oldAddr = (process.env.OLD_VALIDATOR_DEPOSIT_REDEEM || DEFAULT_OLD).trim();

  if (!ethers.isAddress(oldAddr) || !ethers.isAddress(newAddr)) {
    throw new Error("Invalid old/new ValidatorDepositRedeem address");
  }
  if (oldAddr.toLowerCase() === newAddr.toLowerCase()) {
    throw new Error("Old and new addresses are the same");
  }

  const { ethers: ethersHH } = await networkModule.connect();
  const [signer] = await ethersHH.getSigners();
  const me = await signer.getAddress();

  const oldContract = await ethersHH.getContractAt(
    [
      "function admins(address) view returns (bool)",
      "function withdrawNative(address to, uint256 amount) external",
    ],
    oldAddr,
    signer
  );

  const isAdmin = await oldContract.admins(me);
  if (!isAdmin) {
    throw new Error(`Signer ${me} is not contract admin on old ValidatorDepositRedeem ${oldAddr}`);
  }

  const provider = ethersHH.provider;
  const balance = await provider.getBalance(oldAddr);
  if (balance === 0n) {
    console.log("Old contract balance is 0 — nothing to migrate.");
    return;
  }

  console.log("=".repeat(60));
  console.log("Migrate ValidatorDepositRedeem native CNET balance");
  console.log("=".repeat(60));
  console.log("signer:", me);
  console.log("from (old):", oldAddr);
  console.log("to (new):  ", newAddr);
  console.log("amount:    ", ethers.formatEther(balance), "CNET");

  const tx = await oldContract.withdrawNative(newAddr, balance);
  console.log("tx:", tx.hash);
  const receipt = await tx.wait();
  console.log("confirmed block:", receipt?.blockNumber);

  const newBal = await provider.getBalance(newAddr);
  const oldBal = await provider.getBalance(oldAddr);
  console.log("old balance after:", ethers.formatEther(oldBal), "CNET");
  console.log("new balance after:", ethers.formatEther(newBal), "CNET");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
