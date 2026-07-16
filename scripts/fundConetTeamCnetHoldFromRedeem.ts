/**
 * Withdraw 150_000 CNET from ValidatorDepositRedeem → current ConetTeamCnetHold proxy.
 *
 *   npx hardhat run scripts/fundConetTeamCnetHoldFromRedeem.ts --network conet
 *
 * Env:
 *   CONET_TEAM_HOLD_FUND_ETHER — default "150000"
 *   CONET_TEAM_HOLD_TO — override destination proxy
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const REDEEM = "0xc71e246DD78B37C2fABc905D340932F28F503433";

function loadHold(): string {
  const env = process.env.CONET_TEAM_HOLD_TO?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  const p = path.join(root, "deployments/conet-ConetTeamCnetHold.json");
  const d = JSON.parse(fs.readFileSync(p, "utf-8")) as { proxy?: string; address?: string };
  const addr = d.proxy || d.address;
  if (!addr) throw new Error("missing Hold proxy in deployments");
  return ethers.getAddress(addr);
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const signers = await ethersHH.getSigners();
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`期望 224422，当前 ${net.chainId}`);

  const hold = loadHold();
  const amountEther = process.env.CONET_TEAM_HOLD_FUND_ETHER?.trim() || "150000";
  const amount = ethers.parseEther(amountEther);

  const redeemView = new ethers.Contract(
    REDEEM,
    ["function admins(address) view returns (bool)", "function withdrawNative(address to, uint256 amount)"],
    ethersHH.provider
  );
  let admin: (typeof signers)[number] | undefined;
  for (const s of signers) {
    if (await redeemView.admins(s.address)) {
      admin = s;
      break;
    }
  }
  if (!admin) throw new Error("No Hardhat conet signer is ValidatorDepositRedeem.admins");

  const redeemBal = await ethersHH.provider.getBalance(REDEEM);
  const holdBefore = await ethersHH.provider.getBalance(hold);
  console.log("redeem:", REDEEM);
  console.log("hold:", hold);
  console.log("admin:", admin.address);
  console.log("redeem balance:", ethers.formatEther(redeemBal), "CNET");
  console.log("hold before:", ethers.formatEther(holdBefore), "CNET");
  console.log("withdraw:", ethers.formatEther(amount), "CNET");
  if (redeemBal < amount) throw new Error("ValidatorDepositRedeem balance insufficient");

  const redeem = redeemView.connect(admin);
  const tx = await redeem.withdrawNative(hold, amount);
  console.log("withdrawNative tx:", tx.hash);
  const rc = await tx.wait();
  if (rc?.status !== 1) throw new Error("withdrawNative failed");

  const holdAfter = await ethersHH.provider.getBalance(hold);
  const delta = holdAfter - holdBefore;
  console.log("hold after:", ethers.formatEther(holdAfter), "CNET");
  console.log("delta:", ethers.formatEther(delta), "CNET");
  if (delta !== amount) throw new Error(`expected delta ${amount}, got ${delta}`);

  const outPath = path.join(root, "deployments/conet-ConetTeamCnetHold.json");
  if (fs.existsSync(outPath)) {
    const prev = JSON.parse(fs.readFileSync(outPath, "utf-8")) as Record<string, unknown>;
    const funds = Array.isArray(prev.fundsFromRedeem) ? (prev.fundsFromRedeem as unknown[]) : [];
    funds.push({
      at: new Date().toISOString(),
      from: REDEEM,
      amountWei: amount.toString(),
      amountEther,
      tx: tx.hash,
      holdBalanceAfter: holdAfter.toString(),
    });
    prev.fundsFromRedeem = funds;
    fs.writeFileSync(outPath, JSON.stringify(prev, null, 2) + "\n", "utf-8");
    console.log("saved →", outPath);
  }
  console.log("✅ done");
  console.log("Explorer:", `https://mainnet.conet.network/address/${hold}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
