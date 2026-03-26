/**
 * Single entry: same Hardhat connection as deployBeamioAccount.ts, then factory snapshot + tx replay.
 * Prints follow-up commands that use the same PRIVATE_KEY in .env.
 *
 *   npm run debug:workflow:beamio-account-key:base
 */
import { network as networkModule } from "hardhat";
import { runBeamioAccountDeployerDiagnostics } from "./diagReplayCreateCardWithBeamioAccountDeployer.js";

async function main() {
  const { ethers } = await networkModule.connect();
  await runBeamioAccountDeployerDiagnostics(ethers);

  console.log("\n=== Same PRIVATE_KEY workflow (match npm run deploy:base) ===");
  console.log("1) Deploy BeamioAccount impl:  npm run deploy:base");
  console.log("2) Deploy DEBUG card factory:   npm run deploy:debug-usercard-factory:base");
  console.log("3) Create card on DEBUG factory: npm run create:debug-card:base");
  console.log("4) This replay:                 npm run diag:replay-createcard:beamio-account-deployer:base");
  console.log("Legacy signer:                   ALLOW_MASTER_JSON_SIGNER=1 (not recommended vs deploy:base)");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
