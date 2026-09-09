/**
 * Sync BeamioUserCard + Factory Paymaster ABI into SilentPassUI and bizSite abis.ts.
 * Run: npx tsx scripts/syncBeamioCardAbisToUI.ts
 * (Requires: npm run compile)
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
const ABIS_TARGETS = [
  path.join(ROOT, "src/SilentPassUI/src/utils/abis.ts"),
  path.join(ROOT, "src/bizSite/src/utils/abis.ts"),
];

function patchAbisTs(abisPath: string, cardAbiJson: string, factoryAbiJson: string) {
  if (!fs.existsSync(abisPath)) {
    console.error(`❌ abis.ts not found: ${abisPath}`);
    process.exit(1);
  }

  let content = fs.readFileSync(abisPath, "utf-8");

  const cardAbiRegex =
    /export const cardAbi = \[[\s\S]*?\]\s*\n\s*\n\s*export const BeamioCardFactoryAbi/;
  const cardAbiRegex2 =
    /export const cardAbi = \[[\s\S]*?\]\s*\n\s*export const BeamioCardFactoryAbi/;
  if (cardAbiRegex.test(content)) {
    content = content.replace(
      cardAbiRegex,
      `export const cardAbi = ${cardAbiJson}\n\nexport const BeamioCardFactoryAbi`
    );
  } else if (cardAbiRegex2.test(content)) {
    content = content.replace(
      cardAbiRegex2,
      `export const cardAbi = ${cardAbiJson}\n\nexport const BeamioCardFactoryAbi`
    );
  } else {
    console.error(`❌ Could not find cardAbi → BeamioCardFactoryAbi block in ${abisPath}`);
    process.exit(1);
  }

  const factoryAbiRegex = /export const BeamioCardFactoryAbi = \[[\s\S]*$/;
  if (!factoryAbiRegex.test(content)) {
    console.error(`❌ Could not find BeamioCardFactoryAbi block in ${abisPath}`);
    process.exit(1);
  }
  content = content.replace(
    factoryAbiRegex,
    `export const BeamioCardFactoryAbi = ${factoryAbiJson}\n`
  );

  fs.writeFileSync(abisPath, content);
  console.log(`✅ Updated ${path.relative(ROOT, abisPath)}`);
}

function main() {
  for (const [, p] of Object.entries(ARTIFACTS)) {
    if (!fs.existsSync(p)) {
      console.error(`❌ Artifact not found: ${p}`);
      console.error("   Run: npm run compile");
      process.exit(1);
    }
  }

  const cardArtifact = JSON.parse(
    fs.readFileSync(ARTIFACTS.BeamioUserCard, "utf-8")
  );
  const factoryArtifact = JSON.parse(
    fs.readFileSync(ARTIFACTS.BeamioUserCardFactoryPaymasterV07, "utf-8")
  );

  const cardAbiJson = JSON.stringify(cardArtifact.abi);
  const factoryAbiJson = JSON.stringify(factoryArtifact.abi, null, 2);

  for (const target of ABIS_TARGETS) {
    patchAbisTs(target, cardAbiJson, factoryAbiJson);
  }

  console.log(
    "✅ Synced BeamioUserCard + BeamioUserCardFactoryPaymasterV07 ABI → SilentPassUI + bizSite"
  );
}

main();
