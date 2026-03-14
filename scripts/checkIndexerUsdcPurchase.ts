/**
 * 检查用户 USDC 购买 B-Unit 是否已成功记账到 BeamioIndexerDiamond
 *
 * 运行: npx hardhat run scripts/checkIndexerUsdcPurchase.ts --network conet
 * 或: VOTE_USER=0x... VOTE_TX=0x... npx hardhat run scripts/checkIndexerUsdcPurchase.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
async function main() {
  const user = (process.env.VOTE_USER || process.env.USER_ADDR || "0x513087820Af94A7f4d21bC5B68090f3080022E0e").toLowerCase();
  if (!user.startsWith("0x") || user.length !== 42) throw new Error("user 必须是有效地址");

  const addrs = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const diamondAddr = addrs.BeamioIndexerDiamond || "0x9d481CC9Da04456e98aE2FD6eB6F18e37bf72eb5";

  const { ethers } = await networkModule.connect();
  const txCategoryBuintUsdc = ethers.keccak256(ethers.toUtf8Bytes("buintUSDC"));

  const actionFacet = await ethers.getContractAt("ActionFacet", diamondAddr);

  const totalCount = await actionFacet.getAccountActionCount(user);
  console.log("=".repeat(60));
  console.log("检查 Indexer 记账：用户 USDC 购买 B-Unit");
  console.log("=".repeat(60));
  console.log("用户:", user);
  console.log("BeamioIndexerDiamond:", diamondAddr);
  console.log("用户总交易数:", totalCount.toString());

  if (totalCount === 0n) {
    console.log("\n❌ 该用户无任何记账记录");
    return;
  }

  // 获取最近 30 笔（accountActionIds 按添加顺序，末尾为最新）
  const limit = 30n;
  const offset = totalCount > limit ? totalCount - limit : 0n;
  const ids = await actionFacet.getAccountActionIdsPaged(user, offset, limit);
  console.log("\n最近", ids.length, "笔交易 actionId:", ids.map((x: bigint) => x.toString()).join(", "));

  const txCount = await actionFacet.getTransactionCount();
  console.log("Indexer 总交易数 (txCount):", txCount.toString());

  let foundBuintUsdc = 0;
  for (let i = 0; i < ids.length; i++) {
    const [txr] = await actionFacet.getTransactionRecord(ids[i]);
    if (txr.txCategory.toLowerCase() === txCategoryBuintUsdc.toLowerCase()) {
      foundBuintUsdc++;
      console.log("\n✅ 找到 buintUSDC 记账:");
      console.log("  actionId:", ids[i].toString());
      console.log("  txId:", txr.id);
      console.log("  payer:", txr.payer);
      console.log("  payee:", txr.payee);
      console.log("  finalRequestAmountFiat6 (B-Unit):", txr.finalRequestAmountFiat6.toString());
      console.log("  finalRequestAmountUSDC6:", txr.finalRequestAmountUSDC6.toString());
      const hashStr = txr.originalPaymentHash && txr.originalPaymentHash !== ethers.ZeroHash ? txr.originalPaymentHash : "(zero)";
      console.log("  originalPaymentHash (Base purchase tx):", hashStr);
      console.log("  timestamp:", txr.timestamp.toString());
    }
  }

  if (foundBuintUsdc === 0) {
    console.log("\n❌ 最近", ids.length, "笔中无 buintUSDC 记录");
    console.log("  可能记账失败，或记录在更早的交易中");
  } else {
    console.log("\n✅ 共找到", foundBuintUsdc, "笔 buintUSDC 记账");
  }

  // 若指定了投票 tx，检查该 tx 是否发出 TransactionRecordSynced
  const voteTx = process.env.VOTE_TX;
  if (voteTx) {
    const receipt = await ethers.provider.getTransactionReceipt(voteTx);
    if (receipt) {
      const iface = new ethers.Interface([
        "event TransactionRecordSynced(uint256 indexed actionId, bytes32 indexed txId, bytes32 indexed txCategory, address payer, address payee)",
      ]);
      const synced = receipt.logs.filter((log: { address: string }) =>
        log.address.toLowerCase() === diamondAddr.toLowerCase()
      ).some((log: { data: string; topics: string[] }) => {
        try {
          const parsed = iface.parseLog({ data: log.data, topics: log.topics });
          return parsed?.name === "TransactionRecordSynced";
        } catch {
          return false;
        }
      });
      console.log("\n投票 tx", voteTx, "是否发出 TransactionRecordSynced:", synced ? "✅ 是" : "❌ 否");
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
