/**
 * Smoke: create index=0 institutional AA on CoNET via V2 factory (deployer = paymaster).
 *   npx hardhat run ./scripts/smokeCreateInstitutionalAaV2.ts --network conet
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { BEAMIO_AA_FACTORY_V2_PREDICTED } from "./aaInstitutionalV2DeployConstants.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const factoryAddr = ethers.getAddress(
    process.env.BEAMIO_AA_FACTORY_V2 || BEAMIO_AA_FACTORY_V2_PREDICTED
  );
  const fac = await ethers.getContractAt("BeamioFactoryInstitutionalV2", factoryAddr, deployer);
  console.log("factory", factoryAddr, "creator", deployer.address);

  const getAa = fac.getFunction("getAddress(address,uint256)");
  const predicted = ethers.getAddress(await getAa(deployer.address, 0n));
  console.log("predicted AA[0]", predicted);

  let code = await ethers.provider.getCode(predicted);
  if (!code || code === "0x" || code.length <= 2) {
    const tx = await fac.createAccount();
    console.log("createAccount", tx.hash);
    await tx.wait();
    code = await ethers.provider.getCode(predicted);
  } else {
    console.log("AA already deployed");
  }

  // Re-read prediction after create (index may have advanced if first create used index 0)
  const next = await fac.nextIndexOfCreator(deployer.address);
  const aa0 = ethers.getAddress(await getAa(deployer.address, 0n));
  code = await ethers.provider.getCode(aa0);
  if (!code || code === "0x" || code.length <= 2) {
    throw new Error(`No code at AA[0] ${aa0} after create; nextIndex=${next}`);
  }

  const acct = await ethers.getContractAt("BeamioAccountInstitutionalV2", aa0);
  const out = {
    factory: factoryAddr,
    aa: aa0,
    nextIndex: Number(next),
    accountVersion: Number(await acct.accountVersion()),
    factoryOnAa: await acct.factory(),
    soleSelfSigner: await acct.isSoleSelfSigner(),
    owner: await acct.owner(),
  };
  console.log(out);
  const outPath = path.join(__dirname, "../deployments/conet-BeamioAccountInstitutionalV2-sample.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log("Wrote", outPath);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
