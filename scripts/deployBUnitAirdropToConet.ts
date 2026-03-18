/**
 * 部署 BUnitAirdrop 到 CoNET mainnet，并完成权限配置
 *
 * BUint 地址优先级: 1) deployments/conet-addresses.json  2) deployments/conet-BUint.json  3) BUINT_ADDRESS 环境变量  4) 默认
 * 禁止使用已废弃的 BUint 地址，见 conet-addresses.json DEPRECATED_BUINT
 *
 * 运行: npx hardhat run scripts/deployBUnitAirdropToConet.ts --network conet
 *
 * 部署后自动执行:
 * 1. BUint.addAdmin(airdropAddress)
 * 2. BUnitAirdrop.addAdmin(settle_contractAdmin[i]) 对每个 settle_contractAdmin
 * 3. 更新 conet-BUintAirdrop.json、conet-addresses.json
 *
 * 部署后需手动执行（若使用 ConetTreasury / BeamioIndexerDiamond）:
 * - ConetTreasury.setBUnitAirdrop(newAddress)
 * - BeamioIndexerDiamond AdminFacet.setAdmin(newAddress, true)
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const BUINT_JSON_PATH = path.join(__dirname, "..", "deployments", "conet-BUint.json");
const MASTER_PATH = path.join(homedir(), ".master.json");
const CANONICAL_BUINT = "0x4A3E59519eE72B9Dcf376f0617fF0a0a5a1ef879";

function loadBuintAddress(): string {
  if (process.env.BUINT_ADDRESS) return process.env.BUINT_ADDRESS;
  if (fs.existsSync(ADDRESSES_PATH)) {
    const data = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
    const addr = data.BUint || data.contracts?.BUint?.address;
    if (addr) return addr;
  }
  if (fs.existsSync(BUINT_JSON_PATH)) {
    const data = JSON.parse(fs.readFileSync(BUINT_JSON_PATH, "utf-8"));
    const addr = data.contracts?.BUint?.address;
    if (addr) return addr;
  }
  return CANONICAL_BUINT;
}

function assertNotDeprecated(addr: string): void {
  if (!fs.existsSync(ADDRESSES_PATH)) return;
  const data = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const deprecated = (data.DEPRECATED_BUINT || []) as string[];
  const lower = addr.toLowerCase();
  if (deprecated.some((d: string) => d.toLowerCase() === lower)) {
    throw new Error(`禁止使用已废弃的 BUint 地址: ${addr}。当前权威地址见 deployments/conet-addresses.json`);
  }
}

function loadSettleAdmins(): string[] {
  if (!fs.existsSync(MASTER_PATH)) return [];
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const arr = data?.settle_contractAdmin || [];
  return arr.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`));
}

async function main() {
  const BUINT_ADDRESS = loadBuintAddress();
  assertNotDeprecated(BUINT_ADDRESS);

  const settlePks = loadSettleAdmins();

  const { ethers } = await networkModule.connect();
  const settleAddresses = settlePks.map((pk: string) => new ethers.Wallet(pk).address);
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("Deploy BUnitAirdrop on CoNET mainnet");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("BUint:", BUINT_ADDRESS);
  console.log("settle_contractAdmin 数量:", settleAddresses.length);
  console.log("chainId:", net.chainId.toString());

  const Factory = await ethers.getContractFactory("BUnitAirdrop");
  const airdrop = await Factory.deploy(BUINT_ADDRESS, deployer.address);
  await airdrop.waitForDeployment();
  const airdropAddress = await airdrop.getAddress();
  console.log("[1] BUnitAirdrop deployed:", airdropAddress);

  // 2. BUint.addAdmin(airdropAddress)
  const buint = await ethers.getContractAt("BeamioBUnits", BUINT_ADDRESS);
  const tx1 = await buint.addAdmin(airdropAddress);
  await tx1.wait();
  console.log("[2] BUint.addAdmin(airdrop) ok");

  // 3. BUnitAirdrop.addAdmin 对每个 settle_contractAdmin
  for (const addr of settleAddresses) {
    const tx = await airdrop.addAdmin(addr);
    await tx.wait();
    console.log("[3]", `BUnitAirdrop.addAdmin(${addr}) ok`);
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
        address: BUINT_ADDRESS,
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
  console.log("\n[4] saved:", outPath);

  // 5. 更新 conet-addresses.json
  const addrData = fs.existsSync(ADDRESSES_PATH) ? JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8")) : { _comment: "CoNET mainnet 合约地址权威配置", network: "conet", chainId: "224400" };
  addrData.BUnitAirdrop = airdropAddress;
  if (!addrData.BUint) addrData.BUint = BUINT_ADDRESS;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addrData, null, 2) + "\n", "utf-8");
  console.log("[5] updated conet-addresses.json BUnitAirdrop:", airdropAddress);

  console.log("\n部署完成。下一步（若使用）:");
  console.log("  - ConetTreasury.setBUnitAirdrop(" + airdropAddress + ")");
  console.log("  - BeamioIndexerDiamond AdminFacet.setAdmin(" + airdropAddress + ", true)");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
