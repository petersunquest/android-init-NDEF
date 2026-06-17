/**
 * 使用 Nick CREATE2 在任意链部署 BeamioFactoryPaymasterV07，predicted address 仅依赖：
 *   Nick factory + BEAMIO_AA_FACTORY_CREATE2_SALT + initCode(accountLimit, admin)
 *
 * 运行:
 *   npx hardhat run scripts/deployBeamioAAFactoryCreate2.ts --network base
 *   npx hardhat run scripts/deployBeamioAAFactoryCreate2.ts --network conet
 *
 * 环境变量:
 *   BEAMIO_AA_CREATE2_FACTORY — 覆盖默认 Nick factory
 *   DRY_RUN=1 — 只打印 predicted address，不发交易
 *
 * 部署后各链 post-deploy 配置见:
 *   scripts/configureBeamioAAFactoryOnChain.ts
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { concat } from "ethers";
import {
  BEAMIO_AA_FACTORY_ADMIN,
  BEAMIO_AA_FACTORY_CREATE2_SALT,
  BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT,
  NICK_CREATE2_FACTORY,
} from "./aaDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户");

  const factoryAddress = ethers.getAddress(
    process.env.BEAMIO_AA_CREATE2_FACTORY || NICK_CREATE2_FACTORY
  );
  const dryRun = process.env.DRY_RUN === "1";

  const aaFactory = await ethers.getContractFactory("BeamioFactoryPaymasterV07");
  const deployTx = await aaFactory.getDeployTransaction(
    BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT,
    BEAMIO_AA_FACTORY_ADMIN
  );
  const initCode = deployTx.data;
  if (!initCode) throw new Error("无法生成 BeamioFactoryPaymasterV07 initCode");

  const initCodeHash = ethers.keccak256(initCode);
  const predicted = ethers.getAddress(
    "0x" +
      ethers
        .keccak256(
          ethers.solidityPacked(
            ["bytes1", "address", "bytes32", "bytes32"],
            ["0xff", factoryAddress, BEAMIO_AA_FACTORY_CREATE2_SALT, initCodeHash]
          )
        )
        .slice(-40)
  );

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("BeamioFactoryPaymasterV07 CREATE2 deploy");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("deployer EOA:", deployer.address);
  console.log("admin (constructor):", BEAMIO_AA_FACTORY_ADMIN);
  console.log("accountLimit:", BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT);
  console.log("CREATE2 factory:", factoryAddress);
  console.log("salt:", BEAMIO_AA_FACTORY_CREATE2_SALT);
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
        "需先部署 Nick factory 或设置 BEAMIO_AA_CREATE2_FACTORY。"
    );
  }

  if (dryRun) {
    console.log("\nDRY_RUN=1，不发 deploy 交易");
    await writeMeta(net.chainId.toString(), predicted, initCodeHash, factoryAddress);
    return;
  }

  const deployData = nickCreate2DeployCalldata(BEAMIO_AA_FACTORY_CREATE2_SALT, initCode);
  let gasLimit = 15_000_000n;
  try {
    gasLimit = ((await deployer.estimateGas({ to: factoryAddress, data: deployData })) * 120n) / 100n;
  } catch {
    console.warn("estimateGas 失败，使用 gasLimit=15000000");
  }
  const tx = await deployer.sendTransaction({ to: factoryAddress, data: deployData, gasLimit });
  console.log("\ndeploy tx:", tx.hash);
  const receipt = await tx.wait();
  console.log("mined block:", receipt?.blockNumber);

  const codeAfter = await ethers.provider.getCode(predicted);
  if (codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error("CREATE2 deploy 后 predicted address 仍无 code");
  }

  const factory = await ethers.getContractAt("BeamioFactoryPaymasterV07", predicted);
  console.log("\n✅ BeamioFactoryPaymasterV07:", predicted);
  console.log("   admin:", await factory.admin());
  console.log("   accountLimit:", (await factory.accountLimit()).toString());
  console.log("   chainConfigInitialized:", await factory.chainConfigInitialized());

  await writeMeta(net.chainId.toString(), predicted, initCodeHash, factoryAddress);
}

async function writeMeta(
  chainId: string,
  predicted: string,
  initCodeHash: string,
  nickFactory: string
) {
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const metaPath = path.join(deploymentsDir, "beamioAAFactory-create2-meta.json");
  let meta: Record<string, unknown> = {};
  if (fs.existsSync(metaPath)) {
    meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
  }
  meta.predictedAddress = predicted;
  meta.admin = BEAMIO_AA_FACTORY_ADMIN;
  meta.accountLimit = BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT;
  meta.create2Salt = BEAMIO_AA_FACTORY_CREATE2_SALT;
  meta.initCodeHash = initCodeHash;
  meta.nickFactory = nickFactory;
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
