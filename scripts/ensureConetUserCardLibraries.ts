/**
 * Ensure all BeamioUserCard linked libraries exist on CoNET (224422).
 * Reuses known Formatting/Transfer from deployments/conet-addresses.json; deploys any missing libs.
 * Prints JSON for conet-addresses.json merge.
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { deployBeamioUserCardLibraries } from "./beamioUserCardLibraries.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  if (Number(net.chainId) !== 224422) {
    throw new Error(`Expected conet chainId 224422, got ${net.chainId}`);
  }

  const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  const addrData = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, string>;

  const existing = {
    BeamioUserCardFormattingLib: addrData.beamioUserCardFormattingLib,
    BeamioUserCardTransferLib: addrData.beamioUserCardTransferLib,
  };

  console.log("Deployer:", deployer.address);
  console.log("Reusing:", existing);

  const libs = await deployBeamioUserCardLibraries(ethers, deployer, existing);

  const out: Record<string, string> = {
    beamioUserCardFormattingLib: libs.BeamioUserCardFormattingLib,
    beamioUserCardTransferLib: libs.BeamioUserCardTransferLib,
    beamioUserCardAdminGatewayLib: libs.BeamioUserCardAdminGatewayLib,
    beamioUserCardFaucetGatewayLib: libs.BeamioUserCardFaucetGatewayLib,
    beamioUserCardGatewayMintLib: libs.BeamioUserCardGatewayMintLib,
    beamioUserCardGovernanceLib: libs.BeamioUserCardGovernanceLib,
    beamioUserCardIssuedNftGatewayLib: libs.BeamioUserCardIssuedNftGatewayLib,
    beamioUserCardModuleRouterLib: libs.BeamioUserCardModuleRouterLib,
    beamioUserCardRedeemGatewayLib: libs.BeamioUserCardRedeemGatewayLib,
    beamioUserCardReferrerLib: libs.BeamioUserCardReferrerLib,
    beamioUserCardUpdateLib: libs.BeamioUserCardUpdateLib,
    beamioUserCardViewsLib: libs.BeamioUserCardViewsLib,
    referrerRegistryLib: libs.ReferrerRegistryLib,
  };

  Object.assign(addrData, out);
  fs.writeFileSync(addrPath, JSON.stringify(addrData, null, 2) + "\n");
  console.log("\nUpdated", addrPath);
  console.log(JSON.stringify(out, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
