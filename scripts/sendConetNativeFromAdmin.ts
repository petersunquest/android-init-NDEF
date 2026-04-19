/**
 * 使用 conet 网络首个签名者（admin，来自 ~/.master.json）向指定地址转原生 CoNET。
 *
 * 运行: npx hardhat run scripts/sendConetNativeFromAdmin.ts --network conet
 * 可选: AMOUNT_ETH=10 RECIPIENTS=0x...,0x... npx hardhat run scripts/sendConetNativeFromAdmin.ts --network conet
 *
 * 向 serverV4forMinerTotal updateEpochToSC 使用的 epoch 管理员充值:
 *   AMOUNT_ETH=5 TO_MASTER_KEY=epochManagre npx hardhat run scripts/sendConetNativeFromAdmin.ts --network conet
 * （与 masterSetup.epochManagre 同源，字段名与 CoNET-DL 拼写一致）
 */

import { readFileSync, existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { network as networkModule } from "hardhat";

const DEFAULT_RECIPIENTS = [
  "0xcbBB1371973D57e6bD45aC0dfeFD493b59F9D76B",
  "0x6bF3Aa7261e21Be5Fc781Ac09F9475c8A34AfEea",
] as const;

function resolveRecipientFromMasterKey(ethers: typeof import("ethers").ethers, key: string): string {
  const setupPath = join(homedir(), ".master.json");
  if (!existsSync(setupPath)) {
    throw new Error(`未找到 ${setupPath}`);
  }
  const master = JSON.parse(readFileSync(setupPath, "utf-8")) as Record<string, unknown>;
  const pk = master[key];
  if (typeof pk !== "string" || !pk.length) {
    throw new Error(`~/.master.json 中无有效字段 ${key}（私钥 hex）`);
  }
  const normalized = pk.startsWith("0x") ? pk : `0x${pk}`;
  return new ethers.Wallet(normalized).address;
}

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
  const masterKey = process.env.TO_MASTER_KEY?.trim();
  let recipients: string[];
  if (envList?.length) {
    recipients = envList;
  } else if (masterKey) {
    const to = resolveRecipientFromMasterKey(ethers, masterKey);
    console.log(`TO_MASTER_KEY=${masterKey} -> ${to}`);
    recipients = [to];
  } else {
    recipients = [...DEFAULT_RECIPIENTS];
  }

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
