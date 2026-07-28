/**
 * Deploy the TreasuryBridgeV3 UUPS implementation and ERC1967 proxy through
 * Nick's deterministic CREATE2 factory. This script is intentionally
 * single-signer and waits for every receipt before continuing.
 *
 * Usage:
 *   npx hardhat run scripts/deployTreasuryV3Create2.ts --network base
 *   npx hardhat run scripts/deployTreasuryV3Create2.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import {
  deployViaNick,
  initCodeFor,
  NICK_CREATE2_FACTORY,
  saltFromLabel,
} from "./utils/treasuryV3Create2.js";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const DEPLOYMENTS = path.join(ROOT, "deployments");

async function main() {
  const { ethers } = await networkModule.connect();
  const configuredSigners = await ethers.getSigners();
  const deployer = configuredSigners[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  if (chainId !== 8453 && chainId !== 224422) {
    throw new Error(`Treasury V3 only supports Base or CoNET, received ${chainId}`);
  }
  if (chainId === 8453) {
    const legacyDeploymentPath = path.join(ROOT, "deployments", "base-BaseTreasury.json");
    if (fs.existsSync(legacyDeploymentPath)) {
      const expected = String(JSON.parse(fs.readFileSync(legacyDeploymentPath, "utf8")).deployer ?? "").toLowerCase();
      if (expected && (await deployer.getAddress()).toLowerCase() !== expected) {
        throw new Error(`V1/V2 Base deployer mismatch: expected ${expected}, got ${await deployer.getAddress()}`);
      }
    }
  }
  if ((await ethers.provider.getCode(NICK_CREATE2_FACTORY)) === "0x") {
    throw new Error(`Nick CREATE2 factory is not deployed on chain ${chainId}`);
  }

  const miners = (process.env.TREASURY_V3_MINERS ?? deployer.address)
    .split(",")
    .map((address) => address.trim())
    .filter(Boolean);
  const owner = process.env.TREASURY_V3_OWNER ?? deployer.address;
  const implementationFactory = await ethers.getContractFactory("TreasuryBridgeV3");
  const implementation = await deployViaNick(
    deployer,
    await initCodeFor(implementationFactory),
    saltFromLabel(ethers, "bridge-implementation"),
    ethers.provider,
  );

  const bridgeInterface = implementationFactory.interface;
  const initializeData = bridgeInterface.encodeFunctionData("initialize", [owner, miners]);
  const proxyFactory = await ethers.getContractFactory("TreasuryV3ERC1967Proxy");
  const proxyInitCode = await initCodeFor(proxyFactory, implementation.address, initializeData);
  const proxy = await deployViaNick(
    deployer,
    proxyInitCode,
    saltFromLabel(ethers, "bridge-proxy"),
    ethers.provider,
  );

  const output = {
    network: chainId === 8453 ? "base" : "conet",
    chainId,
    deployer: deployer.address,
    nickCreate2Factory: NICK_CREATE2_FACTORY,
    owner,
    miners,
    contracts: {
      TreasuryBridgeV3Implementation: implementation.address,
      TreasuryBridgeV3Proxy: proxy.address,
      ERC1967Proxy: proxy.address,
    },
    initializer: { owner, miners },
    transactions: {
      implementation: implementation.txHash ?? null,
      proxy: proxy.txHash ?? null,
    },
    reused: { implementation: implementation.reused, proxy: proxy.reused },
    createdAt: new Date().toISOString(),
  };
  fs.mkdirSync(DEPLOYMENTS, { recursive: true });
  const outputPath = path.join(
    DEPLOYMENTS,
    `${chainId === 8453 ? "base" : "conet"}-treasury-v3.json`,
  );
  fs.writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`);
  console.log(JSON.stringify(output, null, 2));
  console.log(`Saved ${outputPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
