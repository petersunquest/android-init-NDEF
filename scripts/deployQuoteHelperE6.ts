/**
 * Card Factory 使用的 BeamioQuoteHelperV07 与 BeamioOracle 仍不应通过本脚本重部署。
 * 若需重部署 AA Factory 使用的 QuoteHelper，请改用 scripts/redeployAAQuoteHelperAndUpdateRefs.ts。
 */
async function main() {
  throw new Error(
    "本脚本已禁用。\n" +
    "  - Card Factory QuoteHelper 请继续使用已有地址；\n" +
    "  - AA QuoteHelper 若需重部署，请运行：\n" +
    "    npx hardhat run scripts/redeployAAQuoteHelperAndUpdateRefs.ts --network base"
  );
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
