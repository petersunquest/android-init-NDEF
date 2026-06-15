/**
 * 使用 Nick CREATE2 在任意链部署 ConetTreasury，predicted address 仅依赖：
 *   Nick factory + CONET_TREASURY_CREATE2_SALT + initCode(initialMiner)
 *
 * 运行:
 *   npx hardhat run scripts/deployConetTreasuryCreate2.ts --network conet
 *   npx hardhat run scripts/deployConetTreasuryCreate2.ts --network base
 *
 * 环境变量:
 *   CONET_TREASURY_CREATE2_FACTORY — 覆盖默认 Nick factory
 *   DRY_RUN=1 — 只打印 predicted address，不发交易
 *
 * CoNET 链上 post-deploy 配置（BUnitAirdrop / conetUSDC）见:
 *   scripts/configureConetTreasuryOnConet.ts
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

const NICK_FACTORY_ABI = [
  "function deploy(bytes initCode, bytes32 salt) external returns (address)",
] as const;

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户");

  const factoryAddress = ethers.getAddress(
    process.env.CONET_TREASURY_CREATE2_FACTORY || NICK_CREATE2_FACTORY
  );
  const dryRun = process.env.DRY_RUN === "1";

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

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("ConetTreasury CREATE2 deploy");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("deployer EOA:", deployer.address);
  console.log("initialMiner:", CONET_TREASURY_INITIAL_MINER);
  console.log("CREATE2 factory:", factoryAddress);
  console.log("salt:", CONET_TREASURY_CREATE2_SALT);
  console.log("initCodeHash:", initCodeHash);
  console.log("predicted address:", predicted);

  const existing = await ethers.provider.getCode(predicted);
  if (existing !== "0x" && existing.length > 2) {
    console.log("\n✅ 合约已存在于 predicted address，跳过部署");
    await writeMeta(net.chainId.toString(), predicted, initCodeHash, factoryAddress);
    return;
  }

  const factoryCode = await ethers.provider.getCode(factoryAddress);
  if (factoryCode === "0x" || factoryCode.length <= 2) {
    throw new Error(
      `CREATE2 factory 无 code: ${factoryAddress}。` +
        "需先部署 Nick factory 或设置 CONET_TREASURY_CREATE2_FACTORY。"
    );
  }

  if (dryRun) {
    console.log("\nDRY_RUN=1，不发 deploy 交易");
    await writeMeta(net.chainId.toString(), predicted, initCodeHash, factoryAddress);
    return;
  }

  const nick = new ethers.Contract(factoryAddress, NICK_FACTORY_ABI, deployer);
  const tx = await nick.deploy(initCode, CONET_TREASURY_CREATE2_SALT);
  console.log("\ndeploy tx:", tx.hash);
  const receipt = await tx.wait();
  console.log("mined block:", receipt?.blockNumber);

  const codeAfter = await ethers.provider.getCode(predicted);
  if (codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error("CREATE2 deploy 后 predicted address 仍无 code");
  }

  const treasury = await ethers.getContractAt("ConetTreasury", predicted);
  const isMiner = await treasury.isMiner(CONET_TREASURY_INITIAL_MINER);
  console.log("\n✅ ConetTreasury:", predicted);
  console.log("   isMiner[initialMiner]:", isMiner);
  console.log("   minerCount:", (await treasury.minerCount()).toString());

  await writeMeta(net.chainId.toString(), predicted, initCodeHash, factoryAddress);
}

async function writeMeta(
  chainId: string,
  predicted: string,
  initCodeHash: string,
  factoryAddress: string
) {
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const metaPath = path.join(deploymentsDir, "conetTreasury-create2-meta.json");
  let meta: Record<string, unknown> = {};
  if (fs.existsSync(metaPath)) {
    meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
  }
  meta.predictedAddress = predicted;
  meta.initialMiner = CONET_TREASURY_INITIAL_MINER;
  meta.create2Salt = CONET_TREASURY_CREATE2_SALT;
  meta.initCodeHash = initCodeHash;
  meta.nickFactory = factoryAddress;
  meta.deployments = {
    ...(typeof meta.deployments === "object" && meta.deployments !== null
      ? (meta.deployments as Record<string, string>)
      : {}),
    [chainId]: predicted,
  };
  meta.updatedAt = new Date().toISOString();
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", metaPath);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
