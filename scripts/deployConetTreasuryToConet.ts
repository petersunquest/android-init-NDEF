/**
 * 部署 ConetTreasury 到 CoNET mainnet
 *
 * 与 BaseTreasury 对齐：无 owner/admin，自维护 miner 表，部署者为首个 miner。
 *
 * 1. 部署 ConetTreasury（无参数，deployer 为首个 miner）
 * 2. ConetTreasury.createERC20 创建 conetUSDC（若新部署且无 USDC）
 * 3. BUnitAirdrop.addAdmin(conetTreasuryAddress) 使 ConetTreasury 可调用 mintForUsdcPurchase
 * 4. ConetTreasury.setBUnitAirdrop(bunitAirdropAddress)
 * 5. BUnitAirdrop.setConetTreasuryAndUsdc(conetTreasury, conet-USDC)
 *
 * 运行: npx hardhat run scripts/deployConetTreasuryToConet.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const MASTER_PATH = path.join(homedir(), ".master.json");
const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

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
  let CONET_USDC: string;
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
      "不在 settle_contractAdmin 中。"
    );
  }

  console.log("=".repeat(60));
  console.log("Deploy ConetTreasury on CoNET mainnet");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("chainId:", net.chainId.toString());
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("balance:", ethers.formatEther(balance), "CNET\n");

  // 1. Deploy ConetTreasury（无参数，deployer 为首个 miner）
  const ConetTreasuryFactory = await ethers.getContractFactory("ConetTreasury");
  const treasury = await ConetTreasuryFactory.deploy();
  await treasury.waitForDeployment();
  const treasuryAddress = await treasury.getAddress();
  console.log("[1] ConetTreasury deployed:", treasuryAddress);

  // 2. Create conetUSDC via createERC20（新部署的 ConetTreasury 需创建 USDC）
  const tokenCount = await treasury.createdTokenCount();
  let hasUsdc = false;
  if (tokenCount > 0) {
    const createdTokens = await treasury.getCreatedTokens();
    for (let i = 0; i < tokenCount; i++) {
      const token = await ethers.getContractAt(["function symbol() view returns (string)"], createdTokens[i]);
      if ((await token.symbol()) === "USDC") {
        CONET_USDC = createdTokens[i];
        hasUsdc = true;
        break;
      }
    }
  }
  if (!hasUsdc) {
    const txCreate = await treasury.createERC20("USD Coin", "USDC", 6, BASE_USDC);
    await txCreate.wait();
    const tokens = await treasury.getCreatedTokens();
    CONET_USDC = tokens[tokens.length - 1];
    console.log("[2] createERC20 conetUSDC:", CONET_USDC);
  } else {
    console.log("[2] ConetTreasury 已有 USDC:", CONET_USDC);
  }

  // 3. BUnitAirdrop.addAdmin(conetTreasury) - 使 ConetTreasury 可调用 mintForUsdcPurchase
  const airdropPath = path.join(__dirname, "..", "deployments", "conet-BUintAirdrop.json");
  let airdropAddress: string | undefined;
  if (!fs.existsSync(airdropPath)) {
    console.warn("[2] 未找到 conet-BUintAirdrop.json，跳过 BUnitAirdrop.addAdmin");
  } else {
    const airdropData = JSON.parse(fs.readFileSync(airdropPath, "utf-8"));
    airdropAddress = airdropData?.contracts?.BUnitAirdrop?.address;
    if (airdropAddress) {
      const airdrop = await ethers.getContractAt("BUnitAirdrop", airdropAddress);
      const txAddAdmin = await airdrop.addAdmin(treasuryAddress);
      await txAddAdmin.wait();
      console.log("[3] BUnitAirdrop.addAdmin(ConetTreasury) ok");

      // 4. ConetTreasury.setBUnitAirdrop
      const txSet = await treasury.setBUnitAirdrop(airdropAddress);
      await txSet.wait();
      console.log("[4] ConetTreasury.setBUnitAirdrop ok");

      // 5. BUnitAirdrop.setConetTreasuryAndUsdc(conetTreasury, conet-USDC)
      const txUsdc = await airdrop.setConetTreasuryAndUsdc(treasuryAddress, CONET_USDC);
      await txUsdc.wait();
      console.log("[5] BUnitAirdrop.setConetTreasuryAndUsdc(ConetTreasury, conet-USDC) ok");
    } else {
      console.warn("[2] conet-BUintAirdrop.json 中无 BUnitAirdrop 地址，跳过");
    }
  }

  const minerCount = (await treasury.minerCount()).toString();
  console.log("[6] ConetTreasury.minerCount() =", minerCount);
  console.log("    ConetTreasury.requiredVotes() =", (await treasury.requiredVotes()).toString());

  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      ConetTreasury: {
        address: treasuryAddress,
        minerCount,
        conetUsdc: CONET_USDC,
        bUnitAirdrop: (() => {
          const airdropPath = path.join(__dirname, "..", "deployments", "conet-BUintAirdrop.json");
          if (!fs.existsSync(airdropPath)) return undefined;
          const d = JSON.parse(fs.readFileSync(airdropPath, "utf-8"));
          return d?.contracts?.BUnitAirdrop?.address;
        })(),
      },
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-ConetTreasury.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);

  // 更新 conet-addresses.json
  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  const addrData = fs.existsSync(addrPath) ? JSON.parse(fs.readFileSync(addrPath, "utf-8")) : { _comment: "CoNET mainnet 合约地址权威配置", network: "conet", chainId: "224400" };
  addrData.ConetTreasury = treasuryAddress;
  addrData.conetUsdc = CONET_USDC;
  fs.writeFileSync(addrPath, JSON.stringify(addrData, null, 2) + "\n", "utf-8");
  console.log("updated conet-addresses.json ConetTreasury:", treasuryAddress, "conetUsdc:", CONET_USDC);

  console.log("\nConetTreasury 地址:", treasuryAddress);

  // 6. BeamioIndexerDiamond.setAdmin(BUnitAirdrop, true) - 使 claim/焚烧/USDC 购买可记账
  const indexerPath = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
  const diamondAddr = fs.existsSync(indexerPath)
    ? JSON.parse(fs.readFileSync(indexerPath, "utf-8")).diamond
    : "0x9d481CC9Da04456e98aE2FD6eB6F18e37bf72eb5";
  const masterData = JSON.parse(fs.readFileSync(path.join(homedir(), ".master.json"), "utf-8"));
  const ownerPk = masterData?.settle_contractAdmin?.[0];
  if (ownerPk && airdropAddress) {
    const ownerSigner = new ethers.Wallet(ownerPk.startsWith("0x") ? ownerPk : `0x${ownerPk}`, ethers.provider);
    const diamond = await ethers.getContractAt(
      ["function setAdmin(address admin, bool enabled) external", "function isAdmin(address) view returns (bool)"],
      diamondAddr,
      ownerSigner
    );
    const isAdmin = await diamond.isAdmin(airdropAddress);
    if (!isAdmin) {
      const txAdmin = await diamond.setAdmin(airdropAddress, true);
      await txAdmin.wait();
      console.log("[7] BeamioIndexerDiamond.setAdmin(BUnitAirdrop, true) ok");
    } else {
      console.log("[7] BUnitAirdrop 已是 Indexer admin，跳过");
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
