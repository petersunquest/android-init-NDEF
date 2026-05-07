/**
 * 已弃用：Card Factory 现有独立 QuoteHelper，禁止再用本脚本同时改 AA / Card 两侧。
 * 如需重部署 AA QuoteHelper，请使用：
 *   npx hardhat run scripts/redeployAAQuoteHelperAndUpdateRefs.ts --network base
 */
async function main() {
  throw new Error(
    "scripts/deployQuoteHelperV07AndSetFactories.ts 已弃用；" +
      "请改用 scripts/redeployAAQuoteHelperAndUpdateRefs.ts，仅更新 AA QuoteHelper，不要触碰 Card Factory QuoteHelper。"
  );
}

main().then(() => process.exit(0)).catch((e) => {
  console.error(e);
  process.exit(1);
});
