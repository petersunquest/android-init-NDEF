/**
 * Upgrade BeamioConsumerWalletDashboard implementation (UUPS) on CoNET.
 *
 *   npx hardhat run scripts/upgradeBeamioConsumerWalletDashboardConet.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const DASH_OUT = path.join(__dirname, "..", "deployments", "conet-BeamioConsumerWalletDashboard.json");
const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`Expected 224422, got ${net.chainId}`);

  const prev = JSON.parse(fs.readFileSync(DASH_OUT, "utf-8"));
  const proxyAddress = prev.proxy as string;
  console.log("proxy:", proxyAddress, "deployer:", deployer.address);

  const Impl = await ethers.getContractFactory("BeamioConsumerWalletDashboard");
  const impl = await Impl.deploy();
  await impl.waitForDeployment();
  const implAddress = await impl.getAddress();
  console.log("new impl:", implAddress);

  const dash = Impl.attach(proxyAddress) as InstanceType<typeof Impl>;
  const tx = await dash.upgradeToAndCall(implAddress, "0x");
  await tx.wait();
  console.log("upgraded, tx:", tx.hash);

  const snap = await dash.snapshot(deployer.address, ethers.ZeroAddress);
  console.log("snapshot eoaNative:", snap.eoaNative.toString(), "isL0:", snap.isL0);

  prev.implementation = implAddress;
  prev.timestamp = new Date().toISOString();
  prev.upgradeTx = tx.hash;
  fs.writeFileSync(DASH_OUT, JSON.stringify(prev, null, 2) + "\n");

  const addresses = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  addresses.BeamioConsumerWalletDashboardImpl = implAddress;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
