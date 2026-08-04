/**
 * Nick CREATE2 部署 ConetTreasuryPeer v4 + DepositLib + StableSwapOffline。
 *
 * 运行:
 *   DRY_RUN=1 npx hardhat run scripts/deployConetTreasuryPeerCreate2.ts --network conet
 *   npx hardhat run scripts/deployConetTreasuryPeerCreate2.ts --network conet
 *
 * 环境变量:
 *   CONET_TREASURY — Treasury 地址（默认 CONET_TREASURY_CREATE2_PREDICTED）
 *   DRY_RUN=1 — 只打印 predicted address
 *   SKIP_OFFLINE=1 — 不部署 Offline 薄合约
 *   SKIP_WIRE=1 — 不调用 setPeerModule / setStableSwapOffline
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
  CONET_TREASURY_PEER_STABLE_SWAP_SIG_LIB_CREATE2_SALT,
  CONET_TREASURY_PEER_DEPOSIT_LIB_CREATE2_SALT,
  CONET_TREASURY_PEER_STABLE_SWAP_OFFLINE_CREATE2_SALT,
  NICK_CREATE2_FACTORY,
} from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const WRAPPED_LIB_FQN = "project/src/b-unit/ConetTreasuryPeerWrappedLib.sol:ConetTreasuryPeerWrappedLib";
const STABLE_SWAP_LIB_FQN =
  "project/src/b-unit/ConetTreasuryPeerStableSwapLib.sol:ConetTreasuryPeerStableSwapLib";
const DEPOSIT_LIB_FQN = "project/src/b-unit/ConetTreasuryPeerDepositLib.sol:ConetTreasuryPeerDepositLib";
const STABLE_SWAP_SIG_LIB_FQN =
  "project/src/b-unit/ConetTreasuryPeerStableSwapSigLib.sol:ConetTreasuryPeerStableSwapSigLib";

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
  deployer: { sendTransaction: (tx: { to: string; data: string; gasLimit: bigint }) => Promise<{ hash: string; wait: () => Promise<unknown> }> },
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
  const skipOffline = process.env.SKIP_OFFLINE === "1";
  const skipWire = process.env.SKIP_WIRE === "1";

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

  const depositLibFactory = await ethers.getContractFactory("ConetTreasuryPeerDepositLib");
  const depositLibInitCode = (await depositLibFactory.getDeployTransaction()).data;
  if (!depositLibInitCode) throw new Error("无法生成 ConetTreasuryPeerDepositLib initCode");

  const depositLibAddress = await ensureCreate2Deployed(
    ethers,
    deployer,
    factoryAddress,
    CONET_TREASURY_PEER_DEPOSIT_LIB_CREATE2_SALT,
    depositLibInitCode,
    "ConetTreasuryPeerDepositLib",
    dryRun
  );

  const peerFactory = await ethers.getContractFactory("ConetTreasuryPeer", {
    libraries: {
      [WRAPPED_LIB_FQN]: libAddress,
      [STABLE_SWAP_LIB_FQN]: stableSwapLibAddress,
      [DEPOSIT_LIB_FQN]: depositLibAddress,
    },
  });
  const deployTx = await peerFactory.getDeployTransaction(treasuryAddress);
  const initCode = deployTx.data;
  if (!initCode) throw new Error("无法生成 ConetTreasuryPeer initCode");

  const initCodeHash = ethers.keccak256(initCode);
  const predictedPeer = predictCreate2(ethers, factoryAddress, CONET_TREASURY_PEER_CREATE2_SALT, initCode);

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("ConetTreasuryPeer CREATE2 deploy (v4 + offline StableSwap)");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("deployer:", deployer.address);
  console.log("treasury:", treasuryAddress);
  console.log("wrappedLib:", libAddress);
  console.log("stableSwapLib:", stableSwapLibAddress);
  console.log("depositLib:", depositLibAddress);
  console.log("CREATE2 factory:", factoryAddress);
  console.log("predicted Peer:", predictedPeer);

  const treasuryCode = await ethers.provider.getCode(treasuryAddress);
  if (treasuryCode === "0x" || treasuryCode.length <= 2) {
    throw new Error(`Treasury 无 code: ${treasuryAddress}；先 deployConetTreasuryCreate2`);
  }

  if (!dryRun) {
    await ensureCreate2Deployed(
      ethers,
      deployer,
      factoryAddress,
      CONET_TREASURY_PEER_CREATE2_SALT,
      initCode,
      "ConetTreasuryPeer",
      false
    );
  } else {
    console.log("\nDRY_RUN=1，不发 Peer deploy 交易");
  }

  let sigLibAddress = ethers.ZeroAddress;
  let offlineAddress = ethers.ZeroAddress;

  if (!skipOffline) {
    const sigLibFactory = await ethers.getContractFactory("ConetTreasuryPeerStableSwapSigLib");
    const sigLibInitCode = (await sigLibFactory.getDeployTransaction()).data;
    if (!sigLibInitCode) throw new Error("无法生成 ConetTreasuryPeerStableSwapSigLib initCode");

    sigLibAddress = await ensureCreate2Deployed(
      ethers,
      deployer,
      factoryAddress,
      CONET_TREASURY_PEER_STABLE_SWAP_SIG_LIB_CREATE2_SALT,
      sigLibInitCode,
      "ConetTreasuryPeerStableSwapSigLib",
      dryRun
    );

    const offlineFactory = await ethers.getContractFactory("ConetTreasuryPeerStableSwapOffline", {
      libraries: {
        [STABLE_SWAP_SIG_LIB_FQN]: sigLibAddress,
      },
    });
    const offlineInit = (await offlineFactory.getDeployTransaction(predictedPeer)).data;
    if (!offlineInit) throw new Error("无法生成 ConetTreasuryPeerStableSwapOffline initCode");
    offlineAddress = predictCreate2(
      ethers,
      factoryAddress,
      CONET_TREASURY_PEER_STABLE_SWAP_OFFLINE_CREATE2_SALT,
      offlineInit
    );
    console.log("predicted Offline:", offlineAddress);

    if (!dryRun) {
      await ensureCreate2Deployed(
        ethers,
        deployer,
        factoryAddress,
        CONET_TREASURY_PEER_STABLE_SWAP_OFFLINE_CREATE2_SALT,
        offlineInit,
        "ConetTreasuryPeerStableSwapOffline",
        false
      );
    }
  }

  if (!dryRun && !skipWire && offlineAddress !== ethers.ZeroAddress) {
    const peer = await ethers.getContractAt("ConetTreasuryPeer", predictedPeer);
    const currentOffline = await peer.stableSwapOffline();
    if (ethers.getAddress(currentOffline) !== ethers.getAddress(offlineAddress)) {
      const tx = await peer.setStableSwapOffline(offlineAddress);
      console.log("\nsetStableSwapOffline tx:", tx.hash);
      await tx.wait();
    } else {
      console.log("\nstableSwapOffline 已指向", offlineAddress);
    }

    const treasury = await ethers.getContractAt(
      ["function peerModule() view returns (address)", "function setPeerModule(address) external"],
      treasuryAddress
    );
    const currentPeer = await treasury.peerModule();
    if (ethers.getAddress(currentPeer) !== ethers.getAddress(predictedPeer)) {
      const tx2 = await treasury.setPeerModule(predictedPeer);
      console.log("setPeerModule tx:", tx2.hash);
      await tx2.wait();
    } else {
      console.log("peerModule 已指向", predictedPeer);
    }
  }

  await writeMeta({
    chainId: net.chainId.toString(),
    predictedPeer,
    offlineAddress,
    treasuryAddress,
    initCodeHash,
    factoryAddress,
    libAddress,
    stableSwapLibAddress,
    depositLibAddress,
    sigLibAddress,
  });

  console.log("\n✅ Peer:", predictedPeer);
  if (offlineAddress !== ethers.ZeroAddress) console.log("✅ Offline:", offlineAddress);
}

async function writeMeta(args: {
  chainId: string;
  predictedPeer: string;
  offlineAddress: string;
  treasuryAddress: string;
  initCodeHash: string;
  factoryAddress: string;
  libAddress: string;
  stableSwapLibAddress: string;
  depositLibAddress: string;
  sigLibAddress: string;
}) {
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const metaPath = path.join(deploymentsDir, "conetTreasuryPeer-create2-meta.json");
  let meta: Record<string, unknown> = {};
  if (fs.existsSync(metaPath)) meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
  meta.predictedAddress = args.predictedPeer;
  meta.stableSwapOfflineAddress = args.offlineAddress;
  meta.treasuryAddress = args.treasuryAddress;
  meta.wrappedLibAddress = args.libAddress;
  meta.stableSwapLibAddress = args.stableSwapLibAddress;
  meta.depositLibAddress = args.depositLibAddress;
  meta.stableSwapSigLibAddress = args.sigLibAddress;
  meta.create2Salt = CONET_TREASURY_PEER_CREATE2_SALT;
  meta.offlineSalt = CONET_TREASURY_PEER_STABLE_SWAP_OFFLINE_CREATE2_SALT;
  meta.depositLibSalt = CONET_TREASURY_PEER_DEPOSIT_LIB_CREATE2_SALT;
  meta.initCodeHash = args.initCodeHash;
  meta.nickFactory = args.factoryAddress;
  meta.version = "v4-offline-stableswap";
  meta.deployments = {
    ...(typeof meta.deployments === "object" && meta.deployments !== null
      ? (meta.deployments as Record<string, string>)
      : {}),
    [args.chainId]: args.predictedPeer,
  };
  meta.updatedAt = new Date().toISOString();
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2) + "\n", "utf-8");

  const v4Path = path.join(deploymentsDir, "conet-TreasuryPeer-v4.json");
  fs.writeFileSync(
    v4Path,
    JSON.stringify(
      {
        peer: args.predictedPeer,
        stableSwapOffline: args.offlineAddress,
        treasury: args.treasuryAddress,
        wrappedLib: args.libAddress,
        stableSwapLib: args.stableSwapLibAddress,
        depositLib: args.depositLibAddress,
        stableSwapSigLib: args.sigLibAddress,
        create2Salt: CONET_TREASURY_PEER_CREATE2_SALT,
        offlineSalt: CONET_TREASURY_PEER_STABLE_SWAP_OFFLINE_CREATE2_SALT,
        initCodeHash: args.initCodeHash,
        nickFactory: args.factoryAddress,
        chainId: args.chainId,
        version: "v4-offline-stableswap",
        updatedAt: meta.updatedAt,
      },
      null,
      2
    ) + "\n",
    "utf-8"
  );
  console.log("\nsaved:", metaPath);
  console.log("saved:", v4Path);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
