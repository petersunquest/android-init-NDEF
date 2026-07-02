/**
 * @deprecated 使用 deployErc20UupsCreate2.ts（UUPS impl + proxy；canonical = proxy 地址不变）。
 *
 * 使用 CREATE2 在任意链部署 BeamioBUnits，predicted address 仅依赖：
 *   Nick factory 地址 + BUINT_CREATE2_SALT + initCode(initialAdmin)
 *
 * 运行:
 *   npx hardhat run scripts/deployBUintCreate2.ts --network conet
 *   npx hardhat run scripts/deployBUintCreate2.ts --network base
 *
 * 环境变量:
 *   BUINT_CREATE2_FACTORY — 覆盖默认 Nick factory（CoNET 无 Nick 时需先部署同址工厂）
 *   DRY_RUN=1 — 只打印 predicted address，不发交易
 */

import { network as networkModule } from "hardhat";
import { concat } from "ethers";
import {
  BUINT_CREATE2_SALT,
  BUINT_INITIAL_ADMIN,
  NICK_CREATE2_FACTORY,
} from "./bunitDeployConstants.js";

/** Nick deterministic deployment proxy：tx.data = salt (32 bytes) || initCode */
function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户");

  const factoryAddress = ethers.getAddress(
    process.env.BUINT_CREATE2_FACTORY || NICK_CREATE2_FACTORY
  );
  const dryRun = process.env.DRY_RUN === "1";

  const buintFactory = await ethers.getContractFactory("BeamioBUnits");
  const deployTx = await buintFactory.getDeployTransaction(BUINT_INITIAL_ADMIN);
  const initCode = deployTx.data;
  if (!initCode) throw new Error("无法生成 BeamioBUnits initCode");

  const initCodeHash = ethers.keccak256(initCode);
  const predicted = ethers.getAddress(
    "0x" +
      ethers
        .keccak256(
          ethers.solidityPacked(
            ["bytes1", "address", "bytes32", "bytes32"],
            ["0xff", factoryAddress, BUINT_CREATE2_SALT, initCodeHash]
          )
        )
        .slice(-40)
  );

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("BeamioBUnits CREATE2 deploy");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("deployer EOA:", deployer.address);
  console.log("initialAdmin:", BUINT_INITIAL_ADMIN);
  console.log("CREATE2 factory:", factoryAddress);
  console.log("salt:", BUINT_CREATE2_SALT);
  console.log("initCodeHash:", initCodeHash);
  console.log("predicted address:", predicted);

  const existing = await ethers.provider.getCode(predicted);
  if (existing !== "0x" && existing.length > 2) {
    console.log("\n✅ 合约已存在于 predicted address，跳过部署");
    return;
  }

  const factoryCode = await ethers.provider.getCode(factoryAddress);
  if (factoryCode === "0x" || factoryCode.length <= 2) {
    throw new Error(
      `CREATE2 factory 无 code: ${factoryAddress}。` +
        "CoNET 等链需先部署 Nick factory 或设置 BUINT_CREATE2_FACTORY。"
    );
  }

  if (dryRun) {
    console.log("\nDRY_RUN=1，不发 deploy 交易");
    return;
  }

  const deployData = nickCreate2DeployCalldata(BUINT_CREATE2_SALT, initCode);
  let gasLimit = 15_000_000n;
  try {
    gasLimit = (await deployer.estimateGas({ to: factoryAddress, data: deployData })) * 120n / 100n;
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

  const buint = await ethers.getContractAt("BeamioBUnits", predicted);
  const isAdmin = await buint.admins(BUINT_INITIAL_ADMIN);
  console.log("\n✅ BeamioBUnits:", predicted);
  console.log("   admins[initialAdmin]:", isAdmin);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
