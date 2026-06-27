/**
 * 将旧 BeamioBUnits 的全部 holder 余额（双池 free/paid）迁移到新实例。
 *
 * 语义：旧合约 transfer/transferFrom 永久锁定，唯一入账路径是 admin mint（Transfer from 0x0）。
 * 因此 holder 集合 = 旧合约所有 mint 事件去重 `to`；读取当前 balanceOfAll 已反映 consumeFuel 核销。
 * 新合约用 mintCombo(to, paid, free) 单笔保留两池染色。
 *
 * 运行:
 *   OLD_BUINT=0x.. NEW_BUINT=0x.. DRY_RUN=1 npx hardhat run scripts/migrateBUnitHoldersToNew.ts --network conet
 *   OLD_BUINT=0x.. NEW_BUINT=0x.. npx hardhat run scripts/migrateBUnitHoldersToNew.ts --network conet
 *
 * 环境变量:
 *   OLD_BUINT / NEW_BUINT  必填
 *   FROM_BLOCK             日志起始块（默认 0）
 *   LOG_CHUNK              eth_getLogs 分块大小（默认 50000）
 *   DRY_RUN=1             只打印 holder→(free,paid)，不发 mint
 */

import { network as networkModule } from "hardhat";

const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const ZERO_TOPIC = "0x0000000000000000000000000000000000000000000000000000000000000000";

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const oldAddr = ethers.getAddress((process.env.OLD_BUINT || "").trim());
  const newAddr = ethers.getAddress((process.env.NEW_BUINT || "").trim());
  if (!oldAddr || !newAddr) throw new Error("须设 OLD_BUINT 与 NEW_BUINT");
  const dryRun = process.env.DRY_RUN === "1";
  const fromBlock = BigInt(process.env.FROM_BLOCK || "0");
  const chunk = BigInt(process.env.LOG_CHUNK || "50000");

  const abi = [
    "function balanceOfAll(address) view returns (uint256 total, uint256 free, uint256 paid)",
    "function totalSupply() view returns (uint256)",
    "function admins(address) view returns (bool)",
    "function mintCombo(address to, uint256 paidAmount, uint256 rewardAmount) external",
  ];
  const oldC = new ethers.Contract(oldAddr, abi, signer);
  const newC = new ethers.Contract(newAddr, abi, signer);

  const latest = BigInt(await ethers.provider.getBlockNumber());
  console.log("=".repeat(60));
  console.log("B-Unit holder migration");
  console.log("=".repeat(60));
  console.log("old:", oldAddr);
  console.log("new:", newAddr);
  console.log("signer:", signer.address);
  console.log("scan blocks:", fromBlock.toString(), "→", latest.toString());

  if (!dryRun) {
    const isAdmin = (await newC.admins!(signer.address)) as boolean;
    if (!isAdmin) throw new Error(`signer 非新 BUint admin，无法 mint`);
  }

  // 扫描 mint 事件（topic1 = from = 0x0）收集去重 to
  const holders = new Set<string>();
  for (let start = fromBlock; start <= latest; start += chunk) {
    const end = start + chunk - 1n > latest ? latest : start + chunk - 1n;
    const logs = await ethers.provider.getLogs({
      address: oldAddr,
      topics: [TRANSFER_TOPIC, ZERO_TOPIC],
      fromBlock: Number(start),
      toBlock: Number(end),
    });
    for (const log of logs) {
      const toTopic = log.topics[2];
      if (!toTopic) continue;
      holders.add(ethers.getAddress("0x" + toTopic.slice(26)));
    }
  }
  console.log("unique mint recipients:", holders.size);

  const oldSupply = (await oldC.totalSupply!()) as bigint;
  let sumFree = 0n;
  let sumPaid = 0n;
  const rows: { to: string; free: bigint; paid: bigint }[] = [];
  for (const h of holders) {
    const [, free, paid] = (await oldC.balanceOfAll!(h)) as [bigint, bigint, bigint];
    if (free === 0n && paid === 0n) continue;
    rows.push({ to: h, free, paid });
    sumFree += free;
    sumPaid += paid;
  }
  rows.sort((a, b) => (a.free + a.paid > b.free + b.paid ? -1 : 1));
  console.log("\nholders with balance:", rows.length);
  for (const r of rows) {
    console.log(`  ${r.to}  free=${ethers.formatUnits(r.free, 6)}  paid=${ethers.formatUnits(r.paid, 6)}`);
  }
  console.log("\nsum free:", ethers.formatUnits(sumFree, 6));
  console.log("sum paid:", ethers.formatUnits(sumPaid, 6));
  console.log("sum total:", ethers.formatUnits(sumFree + sumPaid, 6));
  console.log("old totalSupply:", ethers.formatUnits(oldSupply, 6));
  if (sumFree + sumPaid !== oldSupply) {
    console.warn("⚠️ 余额合计 != old totalSupply（可能有未追踪入账路径，请核对）");
  }

  if (dryRun) {
    console.log("\nDRY_RUN=1，不执行 mint");
    return;
  }

  console.log("\n执行 mintCombo 迁移...");
  for (const r of rows) {
    const tx = await newC.mintCombo!(r.to, r.paid, r.free);
    await tx.wait();
    console.log(`  ✅ ${r.to} paid=${ethers.formatUnits(r.paid, 6)} free=${ethers.formatUnits(r.free, 6)} tx=${tx.hash}`);
  }
  const newSupply = (await newC.totalSupply!()) as bigint;
  console.log("\nnew totalSupply:", ethers.formatUnits(newSupply, 6));
  console.log(newSupply === oldSupply ? "✅ 迁移后总量一致" : "⚠️ 总量不一致，请核对");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
