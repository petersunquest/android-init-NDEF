/**
 * 部署 BuintRedeemAirdrop 到 CoNET mainnet，并将该合约加入 BeamioBUnits admin
 *
 * BUint 地址优先级: 同 deployBUnitAirdropToConet.ts（conet-addresses → conet-BUint → env → 默认）
 *
 * 运行: npx hardhat run scripts/deployBuintRedeemAirdropToConet.ts --network conet
 *
 * 部署后自动执行:
 * 1. BeamioBUnits.addAdmin(redeemAddress)
 * 2. 对每个 settle_contractAdmin（来自 ~/.master.json）: 若非 deployer 则 addRedeemAdmin
 * 3. 对 EXTRA_DEFAULT_REDEEM_ADMINS 中尚未在册的地址 addRedeemAdmin（与文档化默认运维一致）
 * 4. 写入 deployments/conet-BuintRedeemAirdrop.json，更新 conet-addresses.json 的 BuintRedeemAirdrop
 *
 * 无需向 ConetTreasury / Indexer 登记（与 BUnitAirdrop 领取/焚烧路径无关）。
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
const CANONICAL_BUINT = "0x4A3E59519eE72B9Dcf376f0617fF0a0a5a1ef879";

/** 除 constructor + settle 外，部署后自动加入的 redeem admin（checksum） */
const EXTRA_DEFAULT_REDEEM_ADMINS: string[] = [
  "0x0981275553A41E00ec1006fe074971285E00c2A3",
  "0x8B48D8249DfC6469357aB25d2488B122dc84D6e7",
  "0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61",
];

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

function loadSettleAdminPrivateKeys(): string[] {
  return mergeConetAdminPrivateKeysFromMasterFile();
}

async function main() {
  const { ethers } = await networkModule.connect();

  const BUINT_ADDRESS = loadBuintAddress();
  assertNotDeprecated(BUINT_ADDRESS);

  const settlePks = loadSettleAdminPrivateKeys();
  const settleAddresses = settlePks.map((pk: string) => new ethers.Wallet(pk).address);

  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("Deploy BuintRedeemAirdrop on CoNET mainnet");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("BUint:", BUINT_ADDRESS);
  console.log("initial redeem admin (constructor):", deployer.address);
  console.log("合并 admin 私钥对应地址 count:", settleAddresses.length);
  console.log("chainId:", net.chainId.toString());

  const Factory = await ethers.getContractFactory("BuintRedeemAirdrop");
  const redeem = await Factory.deploy(BUINT_ADDRESS, deployer.address);
  await redeem.waitForDeployment();
  const redeemAddress = await redeem.getAddress();
  console.log("[1] BuintRedeemAirdrop deployed:", redeemAddress);

  const buint = await ethers.getContractAt("BeamioBUnits", BUINT_ADDRESS);
  const tx1 = await buint.addAdmin(redeemAddress);
  await tx1.wait();
  console.log("[2] BeamioBUnits.addAdmin(redeem) ok");

  const redeemAdminSeen = new Set<string>([deployer.address.toLowerCase()]);
  for (const addr of settleAddresses) {
    if (addr.toLowerCase() === deployer.address.toLowerCase()) continue;
    const tx = await redeem.addRedeemAdmin(addr);
    await tx.wait();
    redeemAdminSeen.add(addr.toLowerCase());
    console.log("[3] BuintRedeemAirdrop.addRedeemAdmin(", addr, ") ok");
  }

  for (const raw of EXTRA_DEFAULT_REDEEM_ADMINS) {
    const addr = ethers.getAddress(raw);
    if (redeemAdminSeen.has(addr.toLowerCase())) continue;
    const tx = await redeem.addRedeemAdmin(addr);
    await tx.wait();
    redeemAdminSeen.add(addr.toLowerCase());
    console.log("[3b] BuintRedeemAirdrop.addRedeemAdmin( extra ", addr, ") ok");
  }

  const bunitAirdropPath = path.join(__dirname, "..", "deployments", "conet-BUintAirdrop.json");
  const prevAdmins: string[] = [];
  if (fs.existsSync(bunitAirdropPath)) {
    const prev = JSON.parse(fs.readFileSync(bunitAirdropPath, "utf-8"));
    prevAdmins.push(...(prev.contracts?.BUint?.admins || []));
  }
  const mintRewardAdminsDoc = [...new Set([...prevAdmins, redeemAddress])];

  const redeemAdminsDoc = [
    ...new Set([deployer.address, ...settleAddresses, ...EXTRA_DEFAULT_REDEEM_ADMINS.map((a) => ethers.getAddress(a))]),
  ];

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    initialRedeemAdmin: deployer.address,
    settle_contractAdmin: settleAddresses,
    timestamp: new Date().toISOString(),
    contracts: {
      BUint: {
        address: BUINT_ADDRESS,
        mintRewardAdminsDoc,
      },
      BuintRedeemAirdrop: {
        address: redeemAddress,
        buint: BUINT_ADDRESS,
        redeemAdmins: redeemAdminsDoc,
        eip712: {
          name: "BuintRedeemAirdrop",
          version: "1",
          redeemWithCode: "RedeemWithCode(address recipient,bytes32 codeHash,uint256 deadline)",
        },
      },
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-BuintRedeemAirdrop.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\n[4] saved:", outPath);

  const addrData = fs.existsSync(ADDRESSES_PATH)
    ? JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"))
    : { _comment: "CoNET mainnet 合约地址权威配置", network: "conet", chainId: "224422" };
  addrData.BuintRedeemAirdrop = redeemAddress;
  if (!addrData.BUint) addrData.BUint = BUINT_ADDRESS;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addrData, null, 2) + "\n", "utf-8");
  console.log("[5] updated conet-addresses.json BuintRedeemAirdrop:", redeemAddress);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
