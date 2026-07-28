/**
 * Print expected deployer address from deployments/*-BeamioAccount.json (same signer as npm run deploy:base).
 *
 *   npx hardhat run scripts/printBeamioAccountDeployer.ts --network base
 *
 * Compare with: cast wallet address --private-key $PRIVATE_KEY
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  const { ethers } = await networkModule.connect();
  const net = await ethers.provider.getNetwork();
  const root = path.join(__dirname, "..", "deployments");
  const file =
    net.chainId === 8453n
      ? path.join(root, "base-BeamioAccount.json")
      : net.chainId === 84532n
        ? path.join(root, "baseSepolia-BeamioAccount.json")
        : path.join(root, `${net.name}-BeamioAccount.json`);
  if (!fs.existsSync(file)) {
    throw new Error(`Missing ${file}`);
  }
  const j = JSON.parse(fs.readFileSync(file, "utf8")) as { deployer?: string };
  if (!j.deployer) throw new Error(`${file} has no deployer`);
  console.log("BeamioAccount deployment file:", path.basename(file));
  console.log("Expected signer (deployer):", j.deployer);
  console.log("Use PRIVATE_KEY for this EOA when running deploy:base / create:debug-card / repro:conet-createcard.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
