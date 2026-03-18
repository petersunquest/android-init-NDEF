/**
 * 部署 BUint + BUnitAirdrop 到 CoNET mainnet，并完成权限配置
 *
 * 1. 部署 BUint（initialOwner = settle_contractAdmin[0]）
 * 2. 部署 BUnitAirdrop（initialOwner = settle_contractAdmin[0]）
 * 3. BUint.addAdmin(airdropAddress)
 * 4. BUnitAirdrop.addAdmin(settle_contractAdmin[i]) 对每个 settle_contractAdmin 地址
 *
 * 运行: npx hardhat run scripts/deployBUintAndAirdropToConet.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const MASTER_PATH = path.join(homedir(), ".master.json");

function loadMasterSetup(): { settle_contractAdmin: string[] } {
  if (!fs.existsSync(MASTER_PATH)) throw new Error("未找到 ~/.master.json");
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  if (!data?.settle_contractAdmin?.length) throw new Error("~/.master.json 中 settle_contractAdmin 为空");
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) =>
      pk.startsWith("0x") ? pk : `0x${pk}`
    ),
  };
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const master = loadMasterSetup();

  const settleAddresses = master.settle_contractAdmin.map((pk: string) =>
    new ethers.Wallet(pk).address
  );
  if (!settleAddresses.includes(deployer.address)) {
    console.warn(
      "警告: 部署者",
      deployer.address,
      "不在 settle_contractAdmin 中。确保 settle_contractAdmin[0] 与 hardhat conet accounts 一致。"
    );
  }

  console.log("=".repeat(60));
  console.log("Deploy BUint + BUnitAirdrop on CoNET mainnet");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("settle_contractAdmin 数量:", settleAddresses.length);
  console.log("chainId:", net.chainId.toString());
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("balance:", ethers.formatEther(balance), "CNET\n");

  // 1. Deploy BeamioBUnits (BUint)
  const BUintFactory = await ethers.getContractFactory("BeamioBUnits");
  const buint = await BUintFactory.deploy();
  await buint.waitForDeployment();
  const buintAddress = await buint.getAddress();
  console.log("[1] BUint deployed:", buintAddress);

  // 2. Deploy BUnitAirdrop
  const AirdropFactory = await ethers.getContractFactory("BUnitAirdrop");
  const airdrop = await AirdropFactory.deploy(buintAddress, deployer.address);
  await airdrop.waitForDeployment();
  const airdropAddress = await airdrop.getAddress();
  console.log("[2] BUnitAirdrop deployed:", airdropAddress);

  // 3. BUint.addAdmin(airdropAddress)
  const tx1 = await buint.addAdmin(airdropAddress);
  await tx1.wait();
  console.log("[3] BUint.addAdmin(airdrop) ok");

  // 4. BUnitAirdrop.addAdmin 对每个 settle_contractAdmin 地址
  for (const addr of settleAddresses) {
    const tx = await airdrop.addAdmin(addr);
    await tx.wait();
    console.log("[4]", `BUnitAirdrop.addAdmin(${addr}) ok`);
  }

  const indexerPath = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
  const beamioIndexerDiamond = fs.existsSync(indexerPath)
    ? JSON.parse(fs.readFileSync(indexerPath, "utf-8")).diamond
    : "0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe";

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    settle_contractAdmin: settleAddresses,
    timestamp: new Date().toISOString(),
    contracts: {
      BUint: {
        address: buintAddress,
        admins: [airdropAddress],
      },
      BUnitAirdrop: {
        address: airdropAddress,
        dailyClaimLimit: "20e6",
        beamioIndexerDiamond,
        admins: settleAddresses,
      },
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-BUintAirdrop.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);

  // 同步更新 conet-addresses.json 为权威配置
  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  const addrData = fs.existsSync(addrPath) ? JSON.parse(fs.readFileSync(addrPath, "utf-8")) : {};
  addrData.BUint = buintAddress;
  fs.writeFileSync(addrPath, JSON.stringify(addrData, null, 2) + "\n", "utf-8");
  console.log("updated conet-addresses.json BUint:", buintAddress);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
