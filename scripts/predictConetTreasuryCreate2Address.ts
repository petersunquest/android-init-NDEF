/**
 * 打印 ConetTreasury CREATE2 跨链同址预测（不发交易）。
 *
 * 运行: npx hardhat run scripts/predictConetTreasuryCreate2Address.ts
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  CONET_TREASURY_CREATE2_SALT,
  CONET_TREASURY_INITIAL_MINER,
  NICK_CREATE2_FACTORY,
} from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function main() {
  const { ethers } = await networkModule.connect();

  const factoryAddress = ethers.getAddress(NICK_CREATE2_FACTORY);
  const treasuryFactory = await ethers.getContractFactory("ConetTreasury");
  const deployTx = await treasuryFactory.getDeployTransaction(CONET_TREASURY_INITIAL_MINER);
  const initCode = deployTx.data;
  if (!initCode) throw new Error("无法生成 ConetTreasury initCode");

  const initCodeHash = ethers.keccak256(initCode);
  const predicted = ethers.getAddress(
    "0x" +
      ethers
        .keccak256(
          ethers.solidityPacked(
            ["bytes1", "address", "bytes32", "bytes32"],
            ["0xff", factoryAddress, CONET_TREASURY_CREATE2_SALT, initCodeHash]
          )
        )
        .slice(-40)
  );

  console.log("ConetTreasury CREATE2 predicted (all chains with same Nick factory + bytecode)");
  console.log("predictedAddress:", predicted);
  console.log("initialMiner:", CONET_TREASURY_INITIAL_MINER);
  console.log("nickFactory:", factoryAddress);
  console.log("salt:", CONET_TREASURY_CREATE2_SALT);
  console.log("initCodeHash:", initCodeHash);

  const meta = {
    predictedAddress: predicted,
    initialMiner: CONET_TREASURY_INITIAL_MINER,
    nickFactory: factoryAddress,
    salt: CONET_TREASURY_CREATE2_SALT,
    initCodeHash,
    updatedAt: new Date().toISOString(),
  };
  const outPath = path.join(__dirname, "..", "deployments", "conetTreasury-create2-meta.json");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(meta, null, 2) + "\n");
  console.log("wrote:", outPath);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
