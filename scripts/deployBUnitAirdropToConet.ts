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
 * 2. BUnitAirdrop.addAdmin：对 ~/.master.json 中 settle_contractAdmin + beamio_Admins + admin 私钥对应地址
 * 3. 从 conet-IndexerDiamond.json 读取 diamond 地址并 setBeamioIndexerDiamond（不可省略，
 *    否则链上保留 address(0)，claimFor 必定 revert）
 * 4. 更新 conet-BUintAirdrop.json、conet-addresses.json
 *
 * 部署后需手动执行（若使用 ConetTreasury / BeamioIndexerDiamond）:
 * - ConetTreasury.setBUnitAirdrop(newAddress)
 * - BeamioIndexerDiamond AdminFacet.setAdmin(newAddress, true)（让 BUnitAirdrop 能写记账）
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { mergeConetAdminPrivateKeysFromMasterFile } from "./utils/conetMasterAdmins.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const BUINT_JSON_PATH = path.join(__dirname, "..", "deployments", "conet-BUint.json");
const CANONICAL_BUINT = "0xC97CEbb4DF827cB2D1453A9Df7FEf6dADa1C16Ad";

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
  return mergeConetAdminPrivateKeysFromMasterFile();
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
  console.log("合并 admin 私钥对应地址数量:", settleAddresses.length);
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

  // 关键：必须真正在链上 setBeamioIndexerDiamond，否则构造函数的 DEFAULT_BEAMIO_INDEXER=address(0)
  // 会让 _indexClaimToBeamioIndexer 调用 IActionFacet(address(0)).syncTokenAction(...)，
  // Solidity 0.8.20 在外部调用前的 extcodesize 预检失败 → 整个 claimFor 回滚（status=0、空 logs）。
  // 之前只把 indexer 写进 JSON 不调 setter，是 224422 重启后 BUnitAirdrop.claimFor 必 revert 的根因。
  if (beamioIndexerDiamond && beamioIndexerDiamond !== "0x0000000000000000000000000000000000000000") {
    const tx4 = await airdrop.setBeamioIndexerDiamond(beamioIndexerDiamond);
    await tx4.wait();
    console.log("[4] BUnitAirdrop.setBeamioIndexerDiamond(", beamioIndexerDiamond, ") ok");
  } else {
    console.warn("[4] WARNING: beamioIndexerDiamond 未解析到有效地址，跳过 setter，链上将保留 address(0)，claimFor 会失败！");
  }

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
  const addrData = fs.existsSync(ADDRESSES_PATH) ? JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8")) : { _comment: "CoNET mainnet 合约地址权威配置", network: "conet", chainId: "224422" };
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
