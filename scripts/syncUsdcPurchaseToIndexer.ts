/**
 * 手动将 USDC 购买 B-Unit 记录同步到 BeamioIndexerDiamond
 *
 * 用于补记 mintForUsdcPurchase 时 syncTokenAction 失败（被 try/catch 吞掉）的记录。
 * 调用者需为 Indexer owner 或 admin。
 *
 * 运行: npx hardhat run scripts/syncUsdcPurchaseToIndexer.ts --network conet
 * 或: USER=0x... USDC_AMOUNT=0.01 npx hardhat run scripts/syncUsdcPurchaseToIndexer.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const MASTER_PATH = path.join(homedir(), ".master.json");
const CONET_CHAIN_ID = 224422n;
const USDC_TO_BUNIT_RATE = 100n;
async function main() {
  const user = (process.env.VOTE_USER || process.env.USER_ADDR || "0x513087820Af94A7f4d21bC5B68090f3080022E0e").toLowerCase();
  if (!user.startsWith("0x") || user.length !== 42) throw new Error("user 必须是有效地址");

  const usdcAmountHuman = process.env.USDC_AMOUNT ? parseFloat(process.env.USDC_AMOUNT) : 0.01;
  const usdcAmount = BigInt(Math.round(usdcAmountHuman * 1e6));
  const bunitAmount = usdcAmount * USDC_TO_BUNIT_RATE;

  const addrs = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const buintAddr = addrs.BUint;
  const diamondAddr = addrs.BeamioIndexerDiamond || "0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe";

  const master = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const pk = master?.settle_contractAdmin?.[0];
  if (!pk) throw new Error("~/.master.json settle_contractAdmin[0] 为空");

  const { ethers } = await networkModule.connect();
  const signer = new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`, ethers.provider);

  // txId: 唯一键，使用随机/时间戳避免与链上已存在冲突
  const txId = ethers.keccak256(
    ethers.toUtf8Bytes(`buintUSDC:${user}:${Date.now()}:${Math.random()}`)
  );
  const txCategory = ethers.keccak256(ethers.toUtf8Bytes("buintUSDC")); // 与 BUnitAirdrop TX_BUINT_USDC 一致

  const actionFacet = await ethers.getContractAt("ActionFacet", diamondAddr, signer);

  const in_ = {
    txId,
    originalPaymentHash: ethers.ZeroHash,
    chainId: CONET_CHAIN_ID,
    txCategory,
    displayJson: "",
    timestamp: Math.floor(Date.now() / 1000),
    payer: buintAddr,
    payee: user,
    finalRequestAmountFiat6: bunitAmount,
    finalRequestAmountUSDC6: usdcAmount,
    isAAAccount: false,
    route: [],
    fees: {
      gasChainType: 0,
      gasWei: 0n,
      gasUSDC6: 0n,
      serviceUSDC6: 0n,
      bServiceUSDC6: 0n,
      bServiceUnits6: 0n,
      feePayer: ethers.ZeroAddress,
    },
    meta: {
      requestAmountFiat6: bunitAmount,
      requestAmountUSDC6: usdcAmount,
      currencyFiat: 0,
      discountAmountFiat6: 0n,
      discountRateBps: 0,
      taxAmountFiat6: 0n,
      taxRateBps: 0,
      afterNotePayer: "",
      afterNotePayee: "",
    },
  };

  console.log("=".repeat(60));
  console.log("手动同步 USDC 购买 B-Unit 到 Indexer");
  console.log("=".repeat(60));
  console.log("user:", user);
  console.log("usdcAmount:", usdcAmount.toString(), `(${usdcAmountHuman} USDC)`);
  console.log("bunitAmount:", bunitAmount.toString());
  console.log("txId:", txId);

  const countBefore = await actionFacet.getTransactionCount();
  const tx = await actionFacet.syncTokenAction(in_);
  await tx.wait();
  const countAfter = await actionFacet.getTransactionCount();
  const actionId = countAfter - 1n;
  console.log("\n✅ syncTokenAction 成功, tx:", tx.hash, "actionId:", actionId.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
