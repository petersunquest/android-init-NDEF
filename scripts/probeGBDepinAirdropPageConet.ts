/**
 * Probe GBDepinAirdrop.airdropDepinPaidPage on CoNET (read-only + optional send).
 *   npx hardhat run scripts/probeGBDepinAirdropPageConet.ts --network conet
 */
import { network } from "hardhat";
import { homedir } from "os";
import fs from "fs";
import path from "path";

const AIRDROP = process.env.GB_DEPIN_AIRDROP || "0xBBd504a88dB1EA143A1D3a83E331F979dD3A5e44";

async function main() {
  const { ethers } = await network.connect();
  const airdrop = await ethers.getContractAt("GBDepinAirdrop", AIRDROP);
  const now = Math.floor(Date.now() / 1000);
  const preview = await airdrop.previewStandardPaidOwed(now);
  console.log("preview owed", preview[0].toString(), "elapsed", preview[1].toString());
  console.log("lastDepinPaidCallAt", (await airdrop.lastDepinPaidCallAt()).toString());

  try {
    await airdrop.airdropDepinPaidPage.staticCall(0, 10, false);
    console.log("staticCall(0,10,false) ok");
  } catch (e: unknown) {
    const err = e as { shortMessage?: string; message?: string; data?: string };
    console.log("staticCall fail:", err.shortMessage ?? err.message);
    if (err.data) console.log("revert data:", err.data);
  }

  try {
    const gas = await airdrop.airdropDepinPaidPage.estimateGas(0, 100, false);
    console.log("estimateGas(0,100,false)", gas.toString());
  } catch (e: unknown) {
    const err = e as { shortMessage?: string; message?: string };
    console.log("estimateGas 100 fail:", err.shortMessage ?? err.message);
  }

  if (process.env.SEND_TX !== "1") return;

  const masterPath = path.join(homedir(), ".master.json");
  const master = JSON.parse(fs.readFileSync(masterPath, "utf-8")) as { settle_contractAdmin?: string[] };
  const pk = master.settle_contractAdmin?.[0];
  if (!pk) throw new Error("no settle_contractAdmin in ~/.master.json");
  const wallet = new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`, ethers.provider);
  const c = airdrop.connect(wallet);
  const tx = await c.airdropDepinPaidPage(0, 10, false, { gasLimit: 4_000_000 });
  console.log("tx", tx.hash);
  await tx.wait();
  console.log("confirmed");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
