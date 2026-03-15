/**
 * 诊断 redeem admin code 为何 active === false
 * 拉取链上 getRedeemAdminList、getRedeemAdminStatus，对比 hash 与时间窗口
 * 运行：npx hardhat run scripts/checkRedeemAdmin0x02BAe5.ts --network base
 */
import { network as networkModule } from "hardhat";

const CARD = "0x02BAe511632354584b198951B42eC73BACBc4E98";
const REDEEM_CODE = "6GyKhZCQL0FXo39byR1f7r";

const cardAbi = [
  "function getRedeemAdminStatus(bytes32 hash) view returns (bool active)",
  "function getRedeemAdminList() view returns (bytes32[] memory)",
];

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;

  console.log("========== Redeem Admin 链上诊断 (Base) ==========");
  console.log("Card:", CARD);
  console.log("RedeemCode:", REDEEM_CODE);
  console.log();

  const card = new ethers.Contract(CARD, cardAbi, provider);

  // 1. 计算 hash（与 BeamioCard.checkRedeemAdminCodeValid 一致）
  const hash = ethers.keccak256(ethers.toUtf8Bytes(REDEEM_CODE.trim()));
  console.log("1. 计算的 hash (keccak256(toUtf8Bytes(code))):");
  console.log("   ", hash);
  console.log();

  // 2. 当前区块时间
  const block = await provider.getBlock("latest");
  const now = block?.timestamp ?? Math.floor(Date.now() / 1000);
  console.log("2. 当前链上时间 (block.timestamp):");
  console.log("   ", now, "→", new Date(Number(now) * 1000).toISOString());
  console.log();

  // 3. 拉取所有 redeem admin hashes
  let hashes: string[] = [];
  try {
    hashes = await card.getRedeemAdminList();
    console.log("3. getRedeemAdminList() 返回", hashes.length, "个 hash:");
    for (let i = 0; i < hashes.length; i++) {
      const h = hashes[i];
      const active = await card.getRedeemAdminStatus(h);
      const match = h.toLowerCase() === hash.toLowerCase() ? " ← 目标" : "";
      console.log("   [", i, "]", h, "→ active:", active, match);
    }
  } catch (e) {
    console.log("3. getRedeemAdminList() 失败:", (e as Error)?.message);
  }
  console.log();

  // 4. 目标 hash 的 getRedeemAdminStatus
  const ourHashInList = hashes.some((h: string) => h.toLowerCase() === hash.toLowerCase());
  console.log("4. 目标 hash 是否在列表中:", ourHashInList);

  try {
    const active = await card.getRedeemAdminStatus(hash);
    console.log("   getRedeemAdminStatus(目标hash) → active:", active);
    if (!active) {
      console.log();
      console.log("❌ active=false 可能原因:");
      if (!ourHashInList) {
        console.log("   - 该 redeem admin 从未创建，或已被兑换/取消（会从列表移除）");
      } else {
        console.log("   - hash 在列表中但 active=false：");
        console.log("     · validAfter 未到（block.timestamp < validAfter）");
        console.log("     · validBefore 已过（block.timestamp > validBefore）");
        console.log("     · 或 redeemAdmin.active 已被 consume/cancel 置为 false");
      }
    } else {
      console.log("   ✅ active=true，code 有效");
    }
  } catch (e) {
    console.log("   getRedeemAdminStatus 调用失败:", (e as Error)?.message);
  }
  console.log();

  console.log("5. 说明: Solidity consumeRedeemAdmin 使用 keccak256(bytes(code))，与 ethers.keccak256(ethers.toUtf8Bytes(code)) 对 ASCII 一致");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
