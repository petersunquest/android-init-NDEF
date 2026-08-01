/**
 * Nick CREATE2 部署 ConetTreasuryPeerWrappedLib + ConetTreasuryPeer（constructor 固定链接 Treasury 同址）。
 *
 * 运行:
 *   npx hardhat run scripts/deployConetTreasuryPeerCreate2.ts --network conet
 *   npx hardhat run scripts/deployConetTreasuryPeerCreate2.ts --network base
 *
 * 环境变量:
 *   CONET_TREASURY — Treasury 地址（默认 CONET_TREASURY_CREATE2_PREDICTED）
 *   CONET_TREASURY_PEER_CREATE2_FACTORY — 覆盖 Nick factory
 *   DRY_RUN=1 — 只打印 predicted address
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { concat } from "ethers";
import {
  CONET_TREASURY_CREATE2_PREDICTED,
  CONET_TREASURY_PEER_CREATE2_SALT,
  CONET_TREASURY_PEER_WRAPPED_LIB_CREATE2_SALT,
  CONET_TREASURY_PEER_STABLE_SWAP_LIB_CREATE2_SALT,
  NICK_CREATE2_FACTORY,
} from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const WRAPPED_LIB_FQN = "project/src/b-unit/ConetTreasuryPeerWrappedLib.sol:ConetTreasuryPeerWrappedLib";
const STABLE_SWAP_LIB_FQN =
  "project/src/b-unit/ConetTreasuryPeerStableSwapLib.sol:ConetTreasuryPeerStableSwapLib";

function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
}

function predictCreate2(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  factoryAddress: string,
  salt: string,
  initCode: string
): string {
  const initCodeHash = ethers.keccak256(initCode);
  return ethers.getAddress(
    "0x" +
      ethers
        .keccak256(
          ethers.solidityPacked(
            ["bytes1", "address", "bytes32", "bytes32"],
            ["0xff", factoryAddress, salt, initCodeHash]
          )
        )
        .slice(-40)
  );
}

async function ensureCreate2Deployed(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  deployer: NonNullable<Awaited<ReturnType<typeof networkModule.connect>>["ethers"]["Signer"]>,
  factoryAddress: string,
  salt: string,
  initCode: string,
  label: string,
  dryRun: boolean
): Promise<string> {
  const predicted = predictCreate2(ethers, factoryAddress, salt, initCode);
  const existing = await ethers.provider.getCode(predicted);
  if (existing !== "0x" && existing.length > 2) {
    console.log(`\n✅ ${label} 已存在:`, predicted);
    return predicted;
  }
  if (dryRun) {
    console.log(`\nDRY_RUN: ${label} 将部署至`, predicted);
    return predicted;
  }
  const deployData = nickCreate2DeployCalldata(salt, initCode);
  let gasLimit = 12_000_000n;
  try {
    gasLimit = ((await deployer.estimateGas({ to: factoryAddress, data: deployData })) * 120n) / 100n;
  } catch {
    console.warn(`${label} estimateGas 失败，使用 gasLimit=12000000`);
  }
  const tx = await deployer.sendTransaction({ to: factoryAddress, data: deployData, gasLimit });
  console.log(`\n${label} deploy tx:`, tx.hash);
  await tx.wait();
  const codeAfter = await ethers.provider.getCode(predicted);
  if (codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error(`${label} CREATE2 后仍无 code: ${predicted}`);
  }
  console.log(`✅ ${label}:`, predicted);
  return predicted;
}

function resolveTreasuryAddress(ethers: { getAddress: (a: string) => string }): string {
  if (process.env.CONET_TREASURY?.trim()) {
    return ethers.getAddress(process.env.CONET_TREASURY.trim());
  }
  const metaPath = path.join(__dirname, "..", "deployments", "conetTreasury-create2-meta.json");
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
    if (meta.predictedAddress) return ethers.getAddress(meta.predictedAddress);
  }
  return CONET_TREASURY_CREATE2_PREDICTED;
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户");

  const treasuryAddress = resolveTreasuryAddress(ethers);
  const factoryAddress = ethers.getAddress(
    process.env.CONET_TREASURY_PEER_CREATE2_FACTORY || NICK_CREATE2_FACTORY
  );
  const dryRun = process.env.DRY_RUN === "1";

  const libFactory = await ethers.getContractFactory("ConetTreasuryPeerWrappedLib");
  const libInitCode = (await libFactory.getDeployTransaction()).data;
  if (!libInitCode) throw new Error("无法生成 ConetTreasuryPeerWrappedLib initCode");

  const libAddress = await ensureCreate2Deployed(
    ethers,
    deployer,
    factoryAddress,
    CONET_TREASURY_PEER_WRAPPED_LIB_CREATE2_SALT,
    libInitCode,
    "ConetTreasuryPeerWrappedLib",
    dryRun
  );

  const stableSwapLibFactory = await ethers.getContractFactory("ConetTreasuryPeerStableSwapLib");
  const stableSwapLibInitCode = (await stableSwapLibFactory.getDeployTransaction()).data;
  if (!stableSwapLibInitCode) throw new Error("无法生成 ConetTreasuryPeerStableSwapLib initCode");

  const stableSwapLibAddress = await ensureCreate2Deployed(
    ethers,
    deployer,
    factoryAddress,
    CONET_TREASURY_PEER_STABLE_SWAP_LIB_CREATE2_SALT,
    stableSwapLibInitCode,
    "ConetTreasuryPeerStableSwapLib",
    dryRun
  );

  const peerFactory = await ethers.getContractFactory("ConetTreasuryPeer", {
    libraries: {
      [WRAPPED_LIB_FQN]: libAddress,
      [STABLE_SWAP_LIB_FQN]: stableSwapLibAddress,
    },
  });
  const deployTx = await peerFactory.getDeployTransaction(treasuryAddress);
  const initCode = deployTx.data;
  if (!initCode) throw new Error("无法生成 ConetTreasuryPeer initCode");

  const initCodeHash = ethers.keccak256(initCode);
  const predicted = predictCreate2(ethers, factoryAddress, CONET_TREASURY_PEER_CREATE2_SALT, initCode);

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("ConetTreasuryPeer CREATE2 deploy (v3 + WrappedLib + StableSwapLib)");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("deployer:", deployer.address);
  console.log("treasury:", treasuryAddress);
  console.log("wrappedLib:", libAddress);
  console.log("stableSwapLib:", stableSwapLibAddress);
  console.log("CREATE2 factory:", factoryAddress);
  console.log("predicted Peer:", predicted);

  const treasuryCode = await ethers.provider.getCode(treasuryAddress);
  if (treasuryCode === "0x" || treasuryCode.length <= 2) {
    throw new Error(`Treasury 无 code: ${treasuryAddress}；先 deployConetTreasuryCreate2`);
  }

  const existing = await ethers.provider.getCode(predicted);
  if (existing !== "0x" && existing.length > 2) {
    console.log("\n✅ Peer 已存在于 predicted address，跳过部署");
    await writeMeta(
      net.chainId.toString(),
      predicted,
      treasuryAddress,
      initCodeHash,
      factoryAddress,
      libAddress,
      stableSwapLibAddress
    );
    return;
  }

  const factoryCode = await ethers.provider.getCode(factoryAddress);
  if (factoryCode === "0x" || factoryCode.length <= 2) {
    throw new Error(`CREATE2 factory 无 code: ${factoryAddress}`);
  }

  if (dryRun) {
    console.log("\nDRY_RUN=1，不发 Peer deploy 交易");
    await writeMeta(
      net.chainId.toString(),
      predicted,
      treasuryAddress,
      initCodeHash,
      factoryAddress,
      libAddress,
      stableSwapLibAddress
    );
    return;
  }

  await ensureCreate2Deployed(
    ethers,
    deployer,
    factoryAddress,
    CONET_TREASURY_PEER_CREATE2_SALT,
    initCode,
    "ConetTreasuryPeer",
    false
  );

  const peer = await ethers.getContractAt("ConetTreasuryPeer", predicted);
  console.log("\n✅ ConetTreasuryPeer:", predicted);
  console.log("   treasury():", await peer.treasury());

  await writeMeta(
    net.chainId.toString(),
    predicted,
    treasuryAddress,
    initCodeHash,
    factoryAddress,
    libAddress,
    stableSwapLibAddress
  );
}

async function writeMeta(
  chainId: string,
  predicted: string,
  treasuryAddress: string,
  initCodeHash: string,
  factoryAddress: string,
  wrappedLibAddress: string,
  stableSwapLibAddress: string
) {
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const metaPath = path.join(deploymentsDir, "conetTreasuryPeer-create2-meta.json");
  let meta: Record<string, unknown> = {};
  if (fs.existsSync(metaPath)) meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
  meta.predictedAddress = predicted;
  meta.treasuryAddress = treasuryAddress;
  meta.wrappedLibAddress = wrappedLibAddress;
  meta.stableSwapLibAddress = stableSwapLibAddress;
  meta.create2Salt = CONET_TREASURY_PEER_CREATE2_SALT;
  meta.wrappedLibSalt = CONET_TREASURY_PEER_WRAPPED_LIB_CREATE2_SALT;
  meta.stableSwapLibSalt = CONET_TREASURY_PEER_STABLE_SWAP_LIB_CREATE2_SALT;
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
