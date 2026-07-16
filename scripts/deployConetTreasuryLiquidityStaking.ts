/**
 * Deploy the CoNET Treasury liquidity-staking UUPS module.
 *
 * This script is intentionally configuration-driven; it does not guess a
 * Treasury address or governance set:
 *
 *   CONET_TREASURY_ADDRESS=0x... \
 *   CONET_STAKING_GOVERNANCE_EOAS=0x...,0x... \
 *   npx hardhat run scripts/deployConetTreasuryLiquidityStaking.ts --network conet
 *
 * The deployer must be a current ConetTreasury miner because the final wiring
 * transaction calls setLiquidityStakingModule().
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import ERC1967ProxyArtifact from "@openzeppelin/contracts/build/contracts/ERC1967Proxy.json" with { type: "json" };

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

function requiredAddress(name: string): string {
  const value = process.env[name]?.trim();
  if (!value || !ethers.isAddress(value)) {
    throw new Error(`${name} must be a valid address`);
  }
  return ethers.getAddress(value);
}

function governanceEoas(): string[] {
  const raw = process.env.CONET_STAKING_GOVERNANCE_EOAS?.trim();
  if (!raw) throw new Error("CONET_STAKING_GOVERNANCE_EOAS is required");
  const values = raw.split(",").map((value) => value.trim()).filter(Boolean);
  if (values.length === 0) throw new Error("CONET_STAKING_GOVERNANCE_EOAS is empty");
  return values.map((value) => {
    if (!ethers.isAddress(value)) throw new Error(`Invalid governance EOA: ${value}`);
    return ethers.getAddress(value);
  });
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [deployer] = await ethersHH.getSigners();
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`Expected CoNET chainId 224422, got ${net.chainId}`);
  }

  const treasuryAddress = requiredAddress("CONET_TREASURY_ADDRESS");
  const governance = governanceEoas();
  const StakingFactory = await ethersHH.getContractFactory("ConetTreasuryLiquidityStaking");
  const implementation = await StakingFactory.deploy();
  await implementation.waitForDeployment();
  const implementationAddress = await implementation.getAddress();
  const initData = StakingFactory.interface.encodeFunctionData("initialize", [
    deployer.address,
    treasuryAddress,
    governance,
  ]);

  const proxyFactory = new ethers.ContractFactory(
    ERC1967ProxyArtifact.abi,
    ERC1967ProxyArtifact.bytecode,
    deployer
  );
  const proxy = await proxyFactory.deploy(implementationAddress, initData);
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();

  const treasury = new ethers.Contract(
    treasuryAddress,
    ["function setLiquidityStakingModule(address) external"],
    deployer
  );
  const wiringTx = await treasury.setLiquidityStakingModule(proxyAddress);
  const wiringReceipt = await wiringTx.wait();

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "ConetTreasuryLiquidityStaking",
    proxyPattern: "ERC1967Proxy",
    upgradeable: true,
    address: proxyAddress,
    proxy: proxyAddress,
    implementation: implementationAddress,
    treasury: treasuryAddress,
    governanceEoas: governance,
    deployer: deployer.address,
    implementationTransactionHash: implementation.deploymentTransaction()?.hash,
    proxyTransactionHash: proxy.deploymentTransaction()?.hash,
    wiringTransactionHash: wiringReceipt?.hash,
    timestamp: new Date().toISOString(),
  };

  const deploymentsDir = path.join(root, "deployments");
  fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-ConetTreasuryLiquidityStaking.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf8");
  console.log("Liquidity staking proxy:", proxyAddress);
  console.log("Implementation:", implementationAddress);
  console.log("Treasury wiring tx:", wiringReceipt?.hash);
  console.log("Saved:", outPath);
  console.log("Next: npm run clean && npm run compile");
  console.log(
    "Verify: node scripts/exportStandardJsonFromBuildInfo.mjs ConetTreasuryLiquidityStaking --full"
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
