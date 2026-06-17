/**
 * 预测 BeamioOracle + BeamioQuoteHelperV07 CREATE2 同址地址。
 * 运行: npx hardhat run scripts/predictBeamioOracleCreate2.ts
 */

import { network as networkModule } from "hardhat";
import { getAddress, keccak256, solidityPacked } from "ethers";
import {
  BEAMIO_ORACLE_ADMIN,
  BEAMIO_ORACLE_CREATE2_SALT,
  BEAMIO_QUOTE_HELPER_ADMIN,
  BEAMIO_QUOTE_HELPER_CREATE2_SALT,
  NICK_CREATE2_FACTORY,
} from "./oracleDeployConstants.js";

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

async function main() {
  const { ethers } = await networkModule.connect();
  const nick = getAddress(NICK_CREATE2_FACTORY);

  const oracleFactory = await ethers.getContractFactory("BeamioOracle");
  const oracleInit = (await oracleFactory.getDeployTransaction(BEAMIO_ORACLE_ADMIN)).data!;
  const oraclePredicted = predictCreate2(nick, BEAMIO_ORACLE_CREATE2_SALT, oracleInit);

  const quoteHelperFactory = await ethers.getContractFactory("BeamioQuoteHelperV07");
  const quoteHelperInit = (
    await quoteHelperFactory.getDeployTransaction(oraclePredicted, BEAMIO_QUOTE_HELPER_ADMIN)
  ).data!;
  const quoteHelperPredicted = predictCreate2(
    nick,
    BEAMIO_QUOTE_HELPER_CREATE2_SALT,
    quoteHelperInit
  );

  console.log("Beamio Oracle stack CREATE2 predicted addresses (Nick factory on all chains):");
  console.log("  Nick CREATE2 factory:", nick);
  console.log("  Oracle salt:        ", BEAMIO_ORACLE_CREATE2_SALT);
  console.log("  QuoteHelper salt:   ", BEAMIO_QUOTE_HELPER_CREATE2_SALT);
  console.log("  owner (both):       ", BEAMIO_ORACLE_ADMIN);
  console.log("");
  console.log("  BeamioOracle:         ", oraclePredicted);
  console.log("  BeamioQuoteHelperV07: ", quoteHelperPredicted);
  console.log("");
  console.log("Update scripts/oracleDeployConstants.ts:");
  console.log(`  BEAMIO_ORACLE_PREDICTED = "${oraclePredicted}"`);
  console.log(`  BEAMIO_QUOTE_HELPER_PREDICTED = "${quoteHelperPredicted}"`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
