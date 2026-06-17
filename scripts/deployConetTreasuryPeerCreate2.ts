/**
 * Nick CREATE2 部署 ConetTreasuryPeer（constructor 固定链接 Treasury 同址）。
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
  NICK_CREATE2_FACTORY,
} from "./conetTreasuryDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
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

  const peerFactory = await ethers.getContractFactory("ConetTreasuryPeer");
  const deployTx = await peerFactory.getDeployTransaction(treasuryAddress);
  const initCode = deployTx.data;
  if (!initCode) throw new Error("无法生成 ConetTreasuryPeer initCode");

  const initCodeHash = ethers.keccak256(initCode);
  const predicted = ethers.getAddress(
    "0x" +
      ethers
        .keccak256(
          ethers.solidityPacked(
            ["bytes1", "address", "bytes32", "bytes32"],
            ["0xff", factoryAddress, CONET_TREASURY_PEER_CREATE2_SALT, initCodeHash]
          )
        )
        .slice(-40)
  );

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("ConetTreasuryPeer CREATE2 deploy");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("deployer:", deployer.address);
  console.log("treasury:", treasuryAddress);
  console.log("CREATE2 factory:", factoryAddress);
  console.log("predicted address:", predicted);

  const treasuryCode = await ethers.provider.getCode(treasuryAddress);
  if (treasuryCode === "0x" || treasuryCode.length <= 2) {
    throw new Error(`Treasury 无 code: ${treasuryAddress}；先 deployConetTreasuryCreate2`);
  }

  const existing = await ethers.provider.getCode(predicted);
  if (existing !== "0x" && existing.length > 2) {
    console.log("\n✅ Peer 已存在于 predicted address，跳过部署");
    await writeMeta(net.chainId.toString(), predicted, treasuryAddress, initCodeHash, factoryAddress);
    return;
  }

  const factoryCode = await ethers.provider.getCode(factoryAddress);
  if (factoryCode === "0x" || factoryCode.length <= 2) {
    throw new Error(`CREATE2 factory 无 code: ${factoryAddress}`);
  }

  if (dryRun) {
    console.log("\nDRY_RUN=1，不发 deploy 交易");
    await writeMeta(net.chainId.toString(), predicted, treasuryAddress, initCodeHash, factoryAddress);
    return;
  }

  const deployData = nickCreate2DeployCalldata(CONET_TREASURY_PEER_CREATE2_SALT, initCode);
  let gasLimit = 12_000_000n;
  try {
    gasLimit = ((await deployer.estimateGas({ to: factoryAddress, data: deployData })) * 120n) / 100n;
  } catch {
    console.warn("estimateGas 失败，使用 gasLimit=12000000");
  }
  const tx = await deployer.sendTransaction({ to: factoryAddress, data: deployData, gasLimit });
  console.log("\ndeploy tx:", tx.hash);
  await tx.wait();

  const codeAfter = await ethers.provider.getCode(predicted);
  if (codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error("CREATE2 deploy 后 predicted address 仍无 code");
  }

  const peer = await ethers.getContractAt("ConetTreasuryPeer", predicted);
  console.log("\n✅ ConetTreasuryPeer:", predicted);
  console.log("   treasury():", await peer.treasury());

  await writeMeta(net.chainId.toString(), predicted, treasuryAddress, initCodeHash, factoryAddress);
}

async function writeMeta(
  chainId: string,
  predicted: string,
  treasuryAddress: string,
  initCodeHash: string,
  factoryAddress: string
) {
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const metaPath = path.join(deploymentsDir, "conetTreasuryPeer-create2-meta.json");
  let meta: Record<string, unknown> = {};
  if (fs.existsSync(metaPath)) meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
  meta.predictedAddress = predicted;
  meta.treasuryAddress = treasuryAddress;
  meta.create2Salt = CONET_TREASURY_PEER_CREATE2_SALT;
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
