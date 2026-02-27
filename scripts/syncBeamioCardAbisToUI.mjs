/**
 * 将 BeamioUserCard 和 BeamioUserCardFactoryPaymasterV07 的编译产物 ABI 同步到 SilentPassUI abis.ts
 * 运行：node scripts/syncBeamioCardAbisToUI.mjs
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
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

for (const [, p] of Object.entries(ARTIFACTS)) {
  if (!fs.existsSync(p)) {
    console.error("Artifact not found:", p);
    console.error("Run: npx hardhat compile");
    process.exit(1);
  }
}
if (!fs.existsSync(ABIS_TS)) {
  console.error("abis.ts not found:", ABIS_TS);
  process.exit(1);
}

const cardArtifact = JSON.parse(fs.readFileSync(ARTIFACTS.BeamioUserCard, "utf-8"));
const factoryArtifact = JSON.parse(
  fs.readFileSync(ARTIFACTS.BeamioUserCardFactoryPaymasterV07, "utf-8")
);

const cardAbiJson = JSON.stringify(cardArtifact.abi);
const factoryAbiJson = JSON.stringify(factoryArtifact.abi, null, 2);

let content = fs.readFileSync(ABIS_TS, "utf-8");

// Replace cardAbi
const cardAbiRegex = /export const cardAbi = \[[\s\S]*?\]\s*\n\s*export const BeamioCardFactoryAbi/;
content = content.replace(
  cardAbiRegex,
  `export const cardAbi = ${cardAbiJson}\n\nexport const BeamioCardFactoryAbi`
);

// Replace BeamioCardFactoryAbi to end of file
const factoryAbiRegex = /export const BeamioCardFactoryAbi = \[[\s\S]*$/;
content = content.replace(
  factoryAbiRegex,
  `export const BeamioCardFactoryAbi = ${factoryAbiJson}\n`
);

fs.writeFileSync(ABIS_TS, content);
console.log("Updated abis.ts with BeamioUserCard and BeamioUserCardFactoryPaymasterV07 ABI");
