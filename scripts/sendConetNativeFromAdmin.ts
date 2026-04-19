/**
 * 使用 conet 网络首个签名者（admin，来自 ~/.master.json）向指定地址转原生 CoNET。
 *
 * 运行: npx hardhat run scripts/sendConetNativeFromAdmin.ts --network conet
 * 可选: AMOUNT_ETH=10 RECIPIENTS=0x...,0x... npx hardhat run scripts/sendConetNativeFromAdmin.ts --network conet
 */

import { network as networkModule } from "hardhat";

const DEFAULT_RECIPIENTS = [
  "0xcbBB1371973D57e6bD45aC0dfeFD493b59F9D76B",
  "0x6bF3Aa7261e21Be5Fc781Ac09F9475c8A34AfEea",
] as const;

async function main() {
  const { ethers } = await networkModule.connect();
  const [admin] = await ethers.getSigners();
  if (!admin) {
    throw new Error("无签名账户：请配置 ~/.master.json（conet 网络 settle_contractAdmin 等）");
  }
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  const amountEth = process.env.AMOUNT_ETH ?? "10";
  const value = ethers.parseEther(amountEth);
  const envList = process.env.RECIPIENTS?.split(",").map((a) => a.trim()).filter(Boolean);
  const recipients = (envList?.length ? envList : [...DEFAULT_RECIPIENTS]) as string[];

  const balance = await ethers.provider.getBalance(admin.address);
  const need = value * BigInt(recipients.length);
  console.log("admin:", admin.address);
  console.log("balance:", ethers.formatEther(balance), "native");
  console.log("amount each:", amountEth, "→", recipients.length, "recipients");

  if (balance < need) {
    throw new Error(`余额不足: ${ethers.formatEther(balance)} < ${ethers.formatEther(need)}`);
  }

  for (const to of recipients) {
    const tx = await admin.sendTransaction({ to, value });
    await tx.wait();
    console.log(`sent ${amountEth} native to ${to} tx: ${tx.hash}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
