/**
 * CREATE2 部署 ConetGB1155 栈（GB + total + userTotal），各链 Nick factory + 固定 salt → 同址。
 *
 * 运行:
 *   npx hardhat run scripts/deployGBStackCreate2.ts --network conet
 *   npx hardhat run scripts/deployGBStackCreate2.ts --network base
 *
 * 环境变量:
 *   GB_CREATE2_FACTORY — 覆盖 Nick factory
 *   SKIP_GB_TOTAL=1 / SKIP_GB_USER_TOTAL=1 — 跳过子合约
 *   DRY_RUN=1 — 只打印 predicted，不发交易
 */

import { network as networkModule } from "hardhat";
import { concat } from "ethers";
import {
  GB_CREATE2_SALT,
  GB_INITIAL_ADMIN,
  GB_START_HOUR_ID,
  GB_START_TIME,
  GB_TOTAL_CREATE2_SALT,
  GB_USER_TOTAL_CREATE2_SALT,
  NICK_CREATE2_FACTORY,
} from "./gbDeployConstants.js";

function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
}

async function predictCreate2(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  factory: string,
  salt: string,
  initCode: string
): Promise<string> {
  return ethers.getAddress(
    "0x" +
      ethers
        .keccak256(
          ethers.solidityPacked(
            ["bytes1", "address", "bytes32", "bytes32"],
            ["0xff", factory, salt, ethers.keccak256(initCode)]
          )
        )
        .slice(-40)
  );
}

async function deployIfNeeded(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  deployer: Awaited<ReturnType<Awaited<ReturnType<typeof networkModule.connect>>["ethers"]["getSigners"]>>[0],
  factoryAddress: string,
  salt: string,
  initCode: string,
  label: string,
  dryRun: boolean
): Promise<string> {
  const predicted = await predictCreate2(ethers, factoryAddress, salt, initCode);
  console.log(`\n${label}`);
  console.log("  predicted:", predicted);

  const existing = await ethers.provider.getCode(predicted);
  if (existing !== "0x" && existing.length > 2) {
    console.log("  ✅ already deployed");
    return predicted;
  }

  if (dryRun) {
    console.log("  DRY_RUN — skip deploy tx");
    return predicted;
  }

  const deployData = nickCreate2DeployCalldata(salt, initCode);
  let gasLimit = 15_000_000n;
  try {
    gasLimit = ((await deployer.estimateGas({ to: factoryAddress, data: deployData })) * 120n) / 100n;
  } catch {
    console.warn("  estimateGas failed, gasLimit=15000000");
  }
  const tx = await deployer.sendTransaction({ to: factoryAddress, data: deployData, gasLimit });
  console.log("  deploy tx:", tx.hash);
  await tx.wait();

  const codeAfter = await ethers.provider.getCode(predicted);
  if (codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error(`${label}: no code at predicted address`);
  }
  console.log("  ✅ deployed");
  return predicted;
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户");

  const factoryAddress = ethers.getAddress(process.env.GB_CREATE2_FACTORY || NICK_CREATE2_FACTORY);
  const dryRun = process.env.DRY_RUN === "1";
  const skipTotal = process.env.SKIP_GB_TOTAL === "1";
  const skipUserTotal = process.env.SKIP_GB_USER_TOTAL === "1";

  const factoryCode = await ethers.provider.getCode(factoryAddress);
  if (factoryCode === "0x" || factoryCode.length <= 2) {
    throw new Error(`CREATE2 factory 无 code: ${factoryAddress}`);
  }

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("ConetGB1155 stack CREATE2 deploy");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("deployer:", deployer.address);
  console.log("initialAdmin:", GB_INITIAL_ADMIN);
  console.log("startTime:", GB_START_TIME.toString());
  console.log("startHourId:", GB_START_HOUR_ID.toString());
  console.log("CREATE2 factory:", factoryAddress);

  const gbFactory = await ethers.getContractFactory("ConetGB1155");
  const gbInit = (
    await gbFactory.getDeployTransaction(GB_START_TIME, GB_START_HOUR_ID, GB_INITIAL_ADMIN)
  ).data!;
  const gb = await deployIfNeeded(ethers, deployer, factoryAddress, GB_CREATE2_SALT, gbInit, "ConetGB1155", dryRun);

  if (!skipTotal) {
    const totalFactory = await ethers.getContractFactory("ConetGB_total");
    const totalInit = (await totalFactory.getDeployTransaction(gb)).data!;
    await deployIfNeeded(
      ethers,
      deployer,
      factoryAddress,
      GB_TOTAL_CREATE2_SALT,
      totalInit,
      "ConetGB_total",
      dryRun
    );
  }

  if (!skipUserTotal) {
    const userTotalFactory = await ethers.getContractFactory("ConetGB_userTotal");
    const userTotalInit = (await userTotalFactory.getDeployTransaction(gb)).data!;
    await deployIfNeeded(
      ethers,
      deployer,
      factoryAddress,
      GB_USER_TOTAL_CREATE2_SALT,
      userTotalInit,
      "ConetGB_userTotal",
      dryRun
    );
  }

  const gbContract = await ethers.getContractAt("ConetGB1155", gb);
  const isIssuer = await gbContract.isIssuer(GB_INITIAL_ADMIN);
  console.log("\n✅ ConetGB1155:", gb);
  console.log("   isIssuer[initialAdmin]:", isIssuer);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
