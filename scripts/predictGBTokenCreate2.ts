/**
 * 预测 GBToken 跨链 CREATE2 同址（Nick factory + 固定 salt + initCode）。
 * 运行: npx hardhat run scripts/predictGBTokenCreate2.ts --network conet
 *   （任意网络皆可，仅用 artifact bytecode 计算，不发交易）
 *
 * 把打印出的 predicted 回填到 gbTokenDeployConstants.ts 的 GBTOKEN_CREATE2_PREDICTED。
 */
import { network as networkModule } from "hardhat";
import { getAddress, keccak256, solidityPacked } from "ethers";
import {
  GBTOKEN_CREATE2_SALT,
  GBTOKEN_INITIAL_ADMIN,
  NICK_CREATE2_FACTORY,
} from "./gbTokenDeployConstants.js";

function predictCreate2(factory: string, salt: string, initCode: string): string {
  return getAddress(
    "0x" +
      keccak256(
        solidityPacked(
          ["bytes1", "address", "bytes32", "bytes32"],
          ["0xff", getAddress(factory), salt, keccak256(initCode)]
        )
      ).slice(-40)
  );
}

async function main() {
  const { ethers } = await networkModule.connect();
  const factory = await ethers.getContractFactory("GBToken");
  const initCode = (await factory.getDeployTransaction(GBTOKEN_INITIAL_ADMIN)).data!;
  const initCodeHash = keccak256(initCode);
  const predicted = predictCreate2(NICK_CREATE2_FACTORY, GBTOKEN_CREATE2_SALT, initCode);

  console.log("=".repeat(60));
  console.log("GBToken CREATE2 prediction");
  console.log("=".repeat(60));
  console.log("initialAdmin:", GBTOKEN_INITIAL_ADMIN);
  console.log("Nick factory:", NICK_CREATE2_FACTORY);
  console.log("salt:        ", GBTOKEN_CREATE2_SALT);
  console.log("initCodeHash:", initCodeHash);
  console.log("predicted:   ", predicted);
  console.log("\n→ 回填 gbTokenDeployConstants.ts GBTOKEN_CREATE2_PREDICTED =", predicted);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
