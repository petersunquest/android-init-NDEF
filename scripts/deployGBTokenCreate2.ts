/**
 * @deprecated 使用 deployErc20UupsCreate2.ts TOKEN=gb（UUPS impl + proxy）。
 *
 * 用 Nick CREATE2 在任意 L1 部署 GBToken（9 位 ERC20 GB），各链同址。
 *
 * 运行:
 *   npx hardhat run scripts/deployGBTokenCreate2.ts --network conet
 *   npx hardhat run scripts/deployGBTokenCreate2.ts --network base
 *
 * 环境变量:
 *   GBTOKEN_CREATE2_FACTORY — 覆盖默认 Nick factory
 *   DRY_RUN=1 — 只打印 predicted address，不发交易
 *
 * 预测地址仅依赖：Nick factory + GBTOKEN_CREATE2_SALT + initCode(GBTOKEN_INITIAL_ADMIN)。
 * 部署后 admin 须 addValidator() 加入跨链 validators，并按需 setBridgePaused(false)。
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { concat, getAddress, keccak256, solidityPacked } from "ethers";
import {
  GBTOKEN_CREATE2_SALT,
  GBTOKEN_INITIAL_ADMIN,
  NICK_CREATE2_FACTORY,
} from "./gbTokenDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
}

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
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户：请配置 ~/.master.json 或 PRIVATE_KEY");

  const factoryAddress = getAddress(
    process.env.GBTOKEN_CREATE2_FACTORY || NICK_CREATE2_FACTORY
  );
  const dryRun = process.env.DRY_RUN === "1";

  const gbFactory = await ethers.getContractFactory("GBToken");
  const initCode = (await gbFactory.getDeployTransaction(GBTOKEN_INITIAL_ADMIN)).data!;
  const initCodeHash = keccak256(initCode);
  const predicted = predictCreate2(factoryAddress, GBTOKEN_CREATE2_SALT, initCode);

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("GBToken CREATE2 deploy");
  console.log("=".repeat(60));
  console.log("chainId:     ", net.chainId.toString());
  console.log("deployer:    ", deployer.address);
  console.log("initialAdmin:", GBTOKEN_INITIAL_ADMIN);
  console.log("Nick factory:", factoryAddress);
  console.log("salt:        ", GBTOKEN_CREATE2_SALT);
  console.log("initCodeHash:", initCodeHash);
  console.log("predicted:   ", predicted);

  const existing = await ethers.provider.getCode(predicted);
  if (existing !== "0x" && existing.length > 2) {
    console.log("\n✅ 合约已存在于 predicted address，跳过部署");
    await record(net.chainId.toString(), predicted, initCodeHash, factoryAddress);
    return;
  }

  const factoryCode = await ethers.provider.getCode(factoryAddress);
  if (factoryCode === "0x" || factoryCode.length <= 2) {
    throw new Error(
      `CREATE2 factory 无 code: ${factoryAddress}。需先部署 Nick factory（CoNET 须用 Arachnid 预签名 tx）。`
    );
  }

  if (dryRun) {
    console.log("\nDRY_RUN=1，不发 deploy 交易");
    return;
  }

  const deployData = nickCreate2DeployCalldata(GBTOKEN_CREATE2_SALT, initCode);
  let gasLimit = 6_000_000n;
  try {
    gasLimit = ((await deployer.estimateGas({ to: factoryAddress, data: deployData })) * 120n) / 100n;
  } catch {
    console.warn("estimateGas 失败，使用 gasLimit=6000000");
  }
  const nonce = await ethers.provider.getTransactionCount(deployer.address, "pending");
  console.log("deployer pending nonce:", nonce);
  const tx = await deployer.sendTransaction({ to: factoryAddress, data: deployData, gasLimit, nonce });
  console.log("\ndeploy tx:", tx.hash);
  const receipt = await tx.wait();
  console.log("mined block:", receipt?.blockNumber);

  const codeAfter = await ethers.provider.getCode(predicted);
  if (codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error("CREATE2 deploy 后 predicted address 仍无 code");
  }

  const gb = await ethers.getContractAt("GBToken", predicted);
  console.log("\n✅ GBToken:", predicted);
  console.log("   name:", await gb.name(), "symbol:", await gb.symbol(), "decimals:", (await gb.decimals()).toString());
  console.log("   admins[initialAdmin]:", await gb.admins(GBTOKEN_INITIAL_ADMIN));

  await record(net.chainId.toString(), predicted, initCodeHash, factoryAddress, receipt?.blockNumber);
}

async function record(
  chainId: string,
  predicted: string,
  initCodeHash: string,
  factoryAddress: string,
  block?: number
) {
  const dir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  const metaPath = path.join(dir, "gbToken-create2-meta.json");
  let meta: Record<string, unknown> = {};
  if (fs.existsSync(metaPath)) meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
  meta.contract = "GBToken";
  meta.source = "src/b-unit/GBToken.sol";
  meta.predictedAddress = predicted;
  meta.initialAdmin = GBTOKEN_INITIAL_ADMIN;
  meta.create2Salt = GBTOKEN_CREATE2_SALT;
  meta.initCodeHash = initCodeHash;
  meta.nickFactory = factoryAddress;
  meta.decimals = 9;
  meta.deployments = {
    ...(typeof meta.deployments === "object" && meta.deployments !== null
      ? (meta.deployments as Record<string, unknown>)
      : {}),
    [chainId]: { address: predicted, block: block ?? null },
  };
  meta.updatedAt = new Date().toISOString();
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", metaPath);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
