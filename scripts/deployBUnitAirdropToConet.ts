/**
 * 部署 BUnitAirdrop 到 CoNET mainnet
 *
 * 运行: BUINT_ADDRESS=0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB npx hardhat run scripts/deployBUnitAirdropToConet.ts --network conet
 *
 * 部署后需执行: BUint.addAdmin(airdropAddress) 以允许空投合约 mint
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BUINT_ADDRESS = process.env.BUINT_ADDRESS || "0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB";

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("Deploy BUnitAirdrop on CoNET mainnet");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("BUint:", BUINT_ADDRESS);
  console.log("chainId:", net.chainId.toString());

  const Factory = await ethers.getContractFactory("BUnitAirdrop");
  const airdrop = await Factory.deploy(BUINT_ADDRESS, deployer.address);
  await airdrop.waitForDeployment();
  const airdropAddress = await airdrop.getAddress();
  console.log("BUnitAirdrop deployed:", airdropAddress);
  console.log("");
  console.log("下一步: 调用 BUint.addAdmin(" + airdropAddress + ") 以允许空投 mint");

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    bunit: BUINT_ADDRESS,
    timestamp: new Date().toISOString(),
    contracts: {
      BUnitAirdrop: {
        address: airdropAddress,
        dailyClaimLimit: "20e6",
        transactionHash: airdrop.deploymentTransaction()?.hash ?? "",
      },
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-BUnitAirdrop.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("saved:", outPath);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
