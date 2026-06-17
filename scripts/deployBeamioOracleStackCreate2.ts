/**
 * Nick CREATE2 部署 BeamioOracle + BeamioQuoteHelperV07（各链同址）。
 *
 * 运行:
 *   npx hardhat run scripts/deployBeamioOracleStackCreate2.ts --network base
 *   CONET_RPC_URL=https://publicrpc.conet.network npx hardhat run scripts/deployBeamioOracleStackCreate2.ts --network conet
 *
 * 环境变量:
 *   BEAMIO_ORACLE_CREATE2_FACTORY — 覆盖 Nick factory
 *   DRY_RUN=1 — 只打印 predicted address，不发交易
 *   SKIP_QUOTE_HELPER=1 — 仅部署 Oracle
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { concat, getAddress, keccak256, solidityPacked } from "ethers";
import {
  BEAMIO_ORACLE_ADMIN,
  BEAMIO_ORACLE_CREATE2_SALT,
  BEAMIO_QUOTE_HELPER_ADMIN,
  BEAMIO_QUOTE_HELPER_CREATE2_SALT,
  NICK_CREATE2_FACTORY,
} from "./oracleDeployConstants.js";

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
          ["0xff", factory, salt, keccak256(initCode)]
        )
      ).slice(-40)
  );
}

async function deployCreate2(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  deployer: Awaited<ReturnType<typeof ethers.getSigners>>[0],
  label: string,
  factoryAddress: string,
  salt: string,
  initCode: string,
  dryRun: boolean
): Promise<string> {
  const predicted = predictCreate2(factoryAddress, salt, initCode);
  const initCodeHash = keccak256(initCode);

  console.log(`\n--- ${label} ---`);
  console.log("salt:", salt);
  console.log("initCodeHash:", initCodeHash);
  console.log("predicted:", predicted);

  const existing = await ethers.provider.getCode(predicted);
  if (existing !== "0x" && existing.length > 2) {
    console.log("✅ 已存在，跳过部署");
    return predicted;
  }

  if (dryRun) {
    console.log("DRY_RUN=1，跳过 deploy");
    return predicted;
  }

  const deployData = nickCreate2DeployCalldata(salt, initCode);
  let gasLimit = 8_000_000n;
  try {
    gasLimit = ((await deployer.estimateGas({ to: factoryAddress, data: deployData })) * 120n) / 100n;
  } catch {
    console.warn("estimateGas 失败，使用 gasLimit=8000000");
  }
  const tx = await deployer.sendTransaction({ to: factoryAddress, data: deployData, gasLimit });
  console.log("deploy tx:", tx.hash);
  await tx.wait();

  const codeAfter = await ethers.provider.getCode(predicted);
  if (codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error(`${label} CREATE2 后 predicted address 仍无 code`);
  }
  console.log("✅ 部署成功:", predicted);
  return predicted;
}

async function writeMeta(
  chainId: string,
  oracle: string,
  quoteHelper: string,
  nickFactory: string,
  oracleInitCodeHash: string,
  quoteHelperInitCodeHash: string
) {
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const metaPath = path.join(deploymentsDir, "beamioOracle-create2-meta.json");
  let meta: Record<string, unknown> = {};
  if (fs.existsSync(metaPath)) {
    meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
  }

  meta.predictedOracle = oracle;
  meta.predictedQuoteHelper = quoteHelper;
  meta.owner = BEAMIO_ORACLE_ADMIN;
  meta.oracleSalt = BEAMIO_ORACLE_CREATE2_SALT;
  meta.quoteHelperSalt = BEAMIO_QUOTE_HELPER_CREATE2_SALT;
  meta.oracleInitCodeHash = oracleInitCodeHash;
  meta.quoteHelperInitCodeHash = quoteHelperInitCodeHash;
  meta.nickFactory = nickFactory;
  meta.deployments = {
    ...(typeof meta.deployments === "object" && meta.deployments !== null
      ? (meta.deployments as Record<string, { oracle: string; quoteHelper: string }>)
      : {}),
    [chainId]: { oracle, quoteHelper },
  };
  meta.updatedAt = new Date().toISOString();
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", metaPath);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户");

  const factoryAddress = getAddress(
    process.env.BEAMIO_ORACLE_CREATE2_FACTORY || NICK_CREATE2_FACTORY
  );
  const dryRun = process.env.DRY_RUN === "1";
  const skipQuoteHelper = process.env.SKIP_QUOTE_HELPER === "1";

  const factoryCode = await ethers.provider.getCode(factoryAddress);
  if (factoryCode === "0x" || factoryCode.length <= 2) {
    throw new Error(`CREATE2 factory 无 code: ${factoryAddress}`);
  }

  const oracleFactory = await ethers.getContractFactory("BeamioOracle");
  const oracleInit = (await oracleFactory.getDeployTransaction(BEAMIO_ORACLE_ADMIN)).data!;
  if (!oracleInit) throw new Error("无法生成 BeamioOracle initCode");

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("BeamioOracle stack CREATE2 deploy");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("deployer:", deployer.address);
  console.log("owner:", BEAMIO_ORACLE_ADMIN);
  console.log("CREATE2 factory:", factoryAddress);

  const oracleAddress = await deployCreate2(
    ethers,
    deployer,
    "BeamioOracle",
    factoryAddress,
    BEAMIO_ORACLE_CREATE2_SALT,
    oracleInit,
    dryRun
  );

  let quoteHelperAddress = oracleAddress;
  let quoteHelperInitHash = "";
  if (!skipQuoteHelper) {
    const quoteHelperFactory = await ethers.getContractFactory("BeamioQuoteHelperV07");
    const quoteHelperInit = (
      await quoteHelperFactory.getDeployTransaction(oracleAddress, BEAMIO_QUOTE_HELPER_ADMIN)
    ).data!;
    if (!quoteHelperInit) throw new Error("无法生成 BeamioQuoteHelperV07 initCode");
    quoteHelperInitHash = keccak256(quoteHelperInit);
    quoteHelperAddress = await deployCreate2(
      ethers,
      deployer,
      "BeamioQuoteHelperV07",
      factoryAddress,
      BEAMIO_QUOTE_HELPER_CREATE2_SALT,
      quoteHelperInit,
      dryRun
    );

    const qh = await ethers.getContractAt("BeamioQuoteHelperV07", quoteHelperAddress);
    console.log("[verify] QuoteHelper.oracle():", await qh.oracle());
    console.log("[verify] QuoteHelper.owner():", await qh.owner());
  }

  const oracle = await ethers.getContractAt("BeamioOracle", oracleAddress);
  console.log("[verify] Oracle.owner():", await oracle.owner());
  console.log("[verify] Oracle USD rate:", (await oracle.getRate(1)).toString());

  await writeMeta(
    net.chainId.toString(),
    oracleAddress,
    quoteHelperAddress,
    factoryAddress,
    keccak256(oracleInit),
    quoteHelperInitHash
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
