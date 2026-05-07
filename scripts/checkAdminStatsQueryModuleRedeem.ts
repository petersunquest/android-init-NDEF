/**
 * 诊断 BM_CallFailed (0x36550849)：检查链上 AdminStatsQueryModule 是否识别 createRedeemAdmin。
 * 若 selectorModuleKind(createRedeemAdmin) 返回 ROUTE_INVALID，则需运行 deployAdminStatsQueryModuleForMintLimit.ts 更新模块。
 *
 * 运行：npx hardhat run scripts/checkAdminStatsQueryModuleRedeem.ts --network base
 */
import { network as networkModule } from "hardhat";

const FACTORY = "0x52cc9E977Ca3EA33c69383a41F87f32a71140A52";
const CARD_FROM_ERROR = "0x48952F9EA1231b59e5c5FA1a99BC657B122CFDfD";
const ROUTE_REDEEM = 0;
const ROUTE_INVALID = 255;

async function main() {
  const { ethers } = await networkModule.connect();

  const createRedeemAdmin5Selector = ethers.id("createRedeemAdmin(bytes32,string,uint64,uint64,uint256)").slice(0, 10) as `0x${string}`;
  const createRedeemAdmin4Selector = ethers.id("createRedeemAdmin(bytes32,string,uint64,uint64)").slice(0, 10) as `0x${string}`;

  // 检查失败交易中的卡使用的 gateway
  const card = await ethers.getContractAt(
    ["function factoryGateway() view returns (address)"],
    CARD_FROM_ERROR
  );
  const cardGateway = (await card.factoryGateway()) as string;
  console.log("Card", CARD_FROM_ERROR, "factoryGateway():", cardGateway);
  console.log("Expected Factory:", FACTORY);
  if (cardGateway.toLowerCase() !== FACTORY.toLowerCase()) {
    console.log("⚠️ 卡使用的 Factory 与预期不同，该 Factory 的 AdminStatsQueryModule 可能未更新");
  }

  const factory = await ethers.getContractAt(
    ["function defaultAdminStatsQueryModule() view returns (address)"],
    FACTORY
  );
  const moduleAddr = (await factory.defaultAdminStatsQueryModule()) as string;
  console.log("Factory defaultAdminStatsQueryModule:", moduleAddr);

  const module = await ethers.getContractAt(
    ["function selectorModuleKind(bytes4) view returns (uint8)"],
    moduleAddr
  );
  const kind5 = Number(await module.selectorModuleKind(createRedeemAdmin5Selector));
  const kind4 = Number(await module.selectorModuleKind(createRedeemAdmin4Selector));

  console.log("selectorModuleKind(createRedeemAdmin(...,uint256)):", kind5, kind5 === ROUTE_REDEEM ? "OK (ROUTE_REDEEM)" : kind5 === ROUTE_INVALID ? "FAIL (ROUTE_INVALID)" : `UNEXPECTED (${kind5})`);
  console.log("selectorModuleKind(createRedeemAdmin(...)):", kind4, kind4 === ROUTE_REDEEM ? "OK (ROUTE_REDEEM)" : kind4 === ROUTE_INVALID ? "FAIL (ROUTE_INVALID)" : `UNEXPECTED (${kind4})`);

  if (kind5 === ROUTE_INVALID || kind4 === ROUTE_INVALID) {
    console.log("\n❌ AdminStatsQueryModule 不识别 createRedeemAdmin，导致 BM_CallFailed。");
    console.log("   修复：FACTORY=" + FACTORY + " npx hardhat run scripts/deployAdminStatsQueryModuleForMintLimit.ts --network base");
    process.exit(1);
  }
  console.log("\n✅ AdminStatsQueryModule 正确识别 createRedeemAdmin。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
