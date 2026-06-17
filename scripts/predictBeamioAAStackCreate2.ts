/**
 * 预测 BeamioFactoryPaymasterV07 + 样例 BeamioAccount CREATE2 同址地址。
 * 运行: npx hardhat run scripts/predictBeamioAAStackCreate2.ts
 */

import { network as networkModule } from "hardhat";
import { getAddress, keccak256, AbiCoder, solidityPacked } from "ethers";
import {
  BEAMIO_AA_FACTORY_ADMIN,
  BEAMIO_AA_FACTORY_CREATE2_SALT,
  BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT,
  BEAMIO_AA_PREDICT_SAMPLE_EOA,
  NICK_CREATE2_FACTORY,
} from "./aaDeployConstants.js";

const ENTRY_POINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";

function predictCreate2(factory: string, salt: string, initCode: string): string {
  return getAddress(
    "0x" +
      keccak256(
        solidityPacked(
          ["bytes1", "address", "bytes32", "bytes32"],
          ["0xff", factory, salt, keccak256(initCode)]
        )
      ).slice(-40)
  );
}

function predictAccountAddress(creator: string, index: number, accountInitCode: string): string {
  const salt = keccak256(
    AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [getAddress(creator), BigInt(index)])
  );
  return predictCreate2(NICK_CREATE2_FACTORY, salt, accountInitCode);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const nick = getAddress(NICK_CREATE2_FACTORY);

  const factoryContract = await ethers.getContractFactory("BeamioFactoryPaymasterV07");
  const factoryInit = (
    await factoryContract.getDeployTransaction(
      BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT,
      BEAMIO_AA_FACTORY_ADMIN
    )
  ).data!;
  const factoryPredicted = predictCreate2(nick, BEAMIO_AA_FACTORY_CREATE2_SALT, factoryInit);

  const accountFactory = await ethers.getContractFactory("BeamioAccount");
  const accountInit = (await accountFactory.getDeployTransaction(ENTRY_POINT)).data!;
  const sampleAa = predictAccountAddress(BEAMIO_AA_PREDICT_SAMPLE_EOA, 0, accountInit);

  console.log("Beamio AA stack CREATE2 predicted addresses (Nick factory on all chains):");
  console.log("  Nick CREATE2 factory:", nick);
  console.log("  Factory salt:       ", BEAMIO_AA_FACTORY_CREATE2_SALT);
  console.log("  Factory admin:      ", BEAMIO_AA_FACTORY_ADMIN);
  console.log("  accountLimit:       ", BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT);
  console.log("");
  console.log("  BeamioFactoryPaymasterV07:", factoryPredicted);
  console.log("");
  console.log("  Sample AA (EOA index=0):");
  console.log("    EOA:", BEAMIO_AA_PREDICT_SAMPLE_EOA);
  console.log("    AA: ", sampleAa);
  console.log("");
  console.log("Update scripts/aaDeployConstants.ts BEAMIO_AA_FACTORY_PREDICTED to:");
  console.log(`  "${factoryPredicted}"`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
