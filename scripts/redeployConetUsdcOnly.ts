/**
 * 使用现有 ConetTreasury 重新部署 conetUSDC（工厂创建新 USDC），并更新所有引用。
 *
 * 1. 从 conet-addresses.json 读取 ConetTreasury、BUnitAirdrop
 * 2. ConetTreasury.createERC20("USD Coin", "USDC", 6, BASE_USDC) 创建新 USDC
 * 3. BUnitAirdrop.setConetTreasuryAndUsdc(conetTreasury, newUsdc) — 需 BUnitAirdrop owner
 * 4. 更新 conet-addresses.json、conet-ConetTreasury.json
 *
 * 运行: npx hardhat run scripts/redeployConetUsdcOnly.ts --network conet
 *
 * 注意：调用者需为 ConetTreasury miner；BUnitAirdrop.setConetTreasuryAndUsdc 需 BUnitAirdrop owner。
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const TREASURY_JSON_PATH = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
const MASTER_PATH = path.join(homedir(), ".master.json");

function loadAddresses(): { ConetTreasury: string; BUnitAirdrop: string } {
  if (!fs.existsSync(ADDRESSES_PATH)) {
    throw new Error("未找到 deployments/conet-addresses.json");
  }
  const data = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const treasury = data.ConetTreasury || data.contracts?.ConetTreasury?.address;
  const airdrop = data.BUnitAirdrop || data.contracts?.BUnitAirdrop?.address;
  if (!treasury || !airdrop) {
    throw new Error("conet-addresses.json 缺少 ConetTreasury 或 BUnitAirdrop");
  }
  return { ConetTreasury: treasury, BUnitAirdrop: airdrop };
}

async function main() {
  const addrs = loadAddresses();
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();

  console.log("=".repeat(60));
  console.log("Redeploy conetUSDC via ConetTreasury");
  console.log("=".repeat(60));
  console.log("ConetTreasury:", addrs.ConetTreasury);
  console.log("BUnitAirdrop:", addrs.BUnitAirdrop);
  console.log("caller:", signer.address);
  console.log("Base USDC (baseToken):", BASE_USDC, "\n");

  const treasury = await ethers.getContractAt("ConetTreasury", addrs.ConetTreasury);
  const isMiner = await treasury.isMiner(signer.address);
  if (!isMiner) {
    throw new Error(`调用者 ${signer.address} 非 ConetTreasury miner，无法 createERC20`);
  }

  // 1. Create new USDC
  const txCreate = await treasury.createERC20("USD Coin", "USDC", 6, BASE_USDC);
  await txCreate.wait();
  const tokens = await treasury.getCreatedTokens();
  const newUsdcAddr = tokens[tokens.length - 1];
  console.log("[1] createERC20 完成，新 conetUSDC:", newUsdcAddr);

  // 2. BUnitAirdrop.setConetTreasuryAndUsdc — owner only
  const airdrop = await ethers.getContractAt("BUnitAirdrop", addrs.BUnitAirdrop);
  const owner = await airdrop.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(
      `BUnitAirdrop.setConetTreasuryAndUsdc 需 owner 执行。当前 owner: ${owner}，signer: ${signer.address}`
    );
  }
  const txSet = await airdrop.setConetTreasuryAndUsdc(addrs.ConetTreasury, newUsdcAddr);
  await txSet.wait();
  console.log("[2] BUnitAirdrop.setConetTreasuryAndUsdc ok");

  // 3. Update conet-addresses.json
  const addrData = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const oldUsdc = addrData.conetUsdc;
  addrData.conetUsdc = newUsdcAddr;
  if (oldUsdc && !Array.isArray(addrData.DEPRECATED_CONET_USDC)) {
    addrData.DEPRECATED_CONET_USDC = [oldUsdc];
  } else if (oldUsdc && Array.isArray(addrData.DEPRECATED_CONET_USDC) && !addrData.DEPRECATED_CONET_USDC.includes(oldUsdc)) {
    addrData.DEPRECATED_CONET_USDC.push(oldUsdc);
  }
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addrData, null, 2) + "\n", "utf-8");
  console.log("[3] 已更新 conet-addresses.json conetUsdc:", newUsdcAddr);

  // 4. Update conet-ConetTreasury.json
  const treasuryData = fs.existsSync(TREASURY_JSON_PATH)
    ? JSON.parse(fs.readFileSync(TREASURY_JSON_PATH, "utf-8"))
    : { network: "conet", chainId: "224422", contracts: { ConetTreasury: {} } };
  if (!treasuryData.contracts) treasuryData.contracts = {};
  if (!treasuryData.contracts.ConetTreasury) treasuryData.contracts.ConetTreasury = {};
  treasuryData.contracts.ConetTreasury.conetUsdc = newUsdcAddr;
  treasuryData.contracts.ConetTreasury.address = addrs.ConetTreasury;
  treasuryData.contracts.ConetTreasury.bUnitAirdrop = addrs.BUnitAirdrop;
  fs.writeFileSync(TREASURY_JSON_PATH, JSON.stringify(treasuryData, null, 2) + "\n", "utf-8");
  console.log("[4] 已更新 conet-ConetTreasury.json");

  console.log("\n新 conetUSDC:", newUsdcAddr);
  console.log("下一步: npx hardhat run scripts/verifyConetTreasuryAndUsdc.ts --network conet");
  console.log("       npx tsx scripts/updateConetReferences.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
