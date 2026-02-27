/**
 * 将 BeamioUserCard 和 BeamioUserCardFactoryPaymasterV07 的编译产物 ABI 同步到 SilentPassUI abis.ts
 * 运行：npx tsx scripts/syncBeamioCardAbisToUI.ts
 */
import * as fs from "fs";
import * as path from "path";

const ROOT = path.resolve(__dirname, "..");
const ARTIFACTS = {
  BeamioUserCard: path.join(
    ROOT,
    "artifacts/src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json"
  ),
  BeamioUserCardFactoryPaymasterV07: path.join(
    ROOT,
    "artifacts/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol/BeamioUserCardFactoryPaymasterV07.json"
  ),
};
const ABIS_TS = path.join(ROOT, "src/SilentPassUI/src/utils/abis.ts");

function main() {
  for (const [, p] of Object.entries(ARTIFACTS)) {
    if (!fs.existsSync(p)) {
      console.error(`❌ Artifact not found: ${p}`);
      console.error("   Run: npx hardhat compile");
      process.exit(1);
    }
  }
  if (!fs.existsSync(ABIS_TS)) {
    console.error(`❌ abis.ts not found: ${ABIS_TS}`);
    process.exit(1);
  }

  const cardArtifact = JSON.parse(
    fs.readFileSync(ARTIFACTS.BeamioUserCard, "utf-8")
  );
  const factoryArtifact = JSON.parse(
    fs.readFileSync(ARTIFACTS.BeamioUserCardFactoryPaymasterV07, "utf-8")
  );

  const cardAbiJson = JSON.stringify(cardArtifact.abi);
  const factoryAbiJson = JSON.stringify(factoryArtifact.abi, null, 2);

  let content = fs.readFileSync(ABIS_TS, "utf-8");

  // Replace cardAbi (single line): export const cardAbi = [...] until \n\nexport const BeamioCardFactoryAbi
  const cardAbiRegex =
    /export const cardAbi = \[[\s\S]*?\]\s*\n\s*\n\s*export const BeamioCardFactoryAbi/;
  const cardReplacement = `export const cardAbi = ${cardAbiJson}\n\nexport const BeamioCardFactoryAbi`;
  if (!cardAbiRegex.test(content)) {
    // Try without double newline
    const cardAbiRegex2 =
      /export const cardAbi = \[[\s\S]*?\]\s*\n\s*export const BeamioCardFactoryAbi/;
    content = content.replace(
      cardAbiRegex2,
      `export const cardAbi = ${cardAbiJson}\n\nexport const BeamioCardFactoryAbi`
    );
  } else {
    content = content.replace(cardAbiRegex, cardReplacement);
  }

  // Replace BeamioCardFactoryAbi (last export, to end of file)
  const factoryAbiRegex = /export const BeamioCardFactoryAbi = \[[\s\S]*$/;
  if (!factoryAbiRegex.test(content)) {
    console.error("❌ Could not find BeamioCardFactoryAbi block in abis.ts");
    process.exit(1);
  }
  content = content.replace(
    factoryAbiRegex,
    `export const BeamioCardFactoryAbi = ${factoryAbiJson}\n`
  );

  fs.writeFileSync(ABIS_TS, content);
  console.log(
    "✅ Updated abis.ts with BeamioUserCard and BeamioUserCardFactoryPaymasterV07 ABI"
  );
}

main();
