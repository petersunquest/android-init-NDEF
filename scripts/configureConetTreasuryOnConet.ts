/**
 * CoNET 链 ConetTreasury post-deploy 配置（CREATE2 同址部署后执行）:
 *   createERC20 conetUSDC、BUnitAirdrop 互连、Indexer admin
 *
 * 环境变量:
 *   CONET_TREASURY — 覆盖 Treasury 地址（默认读 deployments/conetTreasury-create2-meta.json predictedAddress）
 *
 * 运行: npx hardhat run scripts/configureConetTreasuryOnConet.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

function resolveTreasuryAddress(): string {
  if (process.env.CONET_TREASURY) {
    return process.env.CONET_TREASURY;
  }
  const metaPath = path.join(__dirname, "..", "deployments", "conetTreasury-create2-meta.json");
  if (fs.existsSync(metaPath)) {
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf-8"));
    if (meta.predictedAddress) return meta.predictedAddress;
  }
  const legacyPath = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
  if (fs.existsSync(legacyPath)) {
    const d = JSON.parse(fs.readFileSync(legacyPath, "utf-8"));
    const addr = d?.contracts?.ConetTreasury?.address;
    if (addr) return addr;
  }
  throw new Error("未找到 ConetTreasury 地址；先 deployConetTreasuryCreate2 或设置 CONET_TREASURY");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const treasuryAddress = resolveTreasuryAddress();
  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddress, signer);

  console.log("=".repeat(60));
  console.log("Configure ConetTreasury on CoNET");
  console.log("=".repeat(60));
  console.log("ConetTreasury:", treasuryAddress);
  console.log("signer:", signer.address);

  let conetUsdc: string | undefined;
  const tokenCount = await treasury.createdTokenCount();
  if (tokenCount > 0) {
    const createdTokens = await treasury.getCreatedTokens();
    for (let i = 0; i < tokenCount; i++) {
      const token = await ethers.getContractAt(["function symbol() view returns (string)"], createdTokens[i]);
      if ((await token.symbol()) === "USDC") {
        conetUsdc = createdTokens[i];
        break;
      }
    }
  }
  if (!conetUsdc) {
    const txCreate = await treasury.createERC20("USD Coin", "USDC", 6, BASE_USDC);
    await txCreate.wait();
    const tokens = await treasury.getCreatedTokens();
    conetUsdc = tokens[tokens.length - 1];
    console.log("[1] createERC20 conetUSDC:", conetUsdc);
  } else {
    console.log("[1] 已有 conetUSDC:", conetUsdc);
  }

  const airdropPath = path.join(__dirname, "..", "deployments", "conet-BUintAirdrop.json");
  if (!fs.existsSync(airdropPath)) {
    console.warn("[2] 未找到 conet-BUintAirdrop.json，跳过 BUnitAirdrop 链接");
    return;
  }
  const airdropData = JSON.parse(fs.readFileSync(airdropPath, "utf-8"));
  const airdropAddress = airdropData?.contracts?.BUnitAirdrop?.address as string | undefined;
  if (!airdropAddress) {
    console.warn("[2] conet-BUintAirdrop.json 无地址，跳过");
    return;
  }

  const airdrop = await ethers.getContractAt("BUnitAirdrop", airdropAddress, signer);
  const treasuryIsAdmin = await airdrop.admins(treasuryAddress);
  if (!treasuryIsAdmin) {
    const txAdd = await airdrop.addAdmin(treasuryAddress);
    await txAdd.wait();
    console.log("[2] BUnitAirdrop.addAdmin(ConetTreasury) ok");
  } else {
    console.log("[2] ConetTreasury 已是 BUnitAirdrop admin");
  }

  const currentAirdrop = await treasury.bunitAirdrop();
  if (currentAirdrop.toLowerCase() !== airdropAddress.toLowerCase()) {
    const txSet = await treasury.setBUnitAirdrop(airdropAddress);
    await txSet.wait();
    console.log("[3] ConetTreasury.setBUnitAirdrop ok");
  } else {
    console.log("[3] bunitAirdrop 已配置");
  }

  const txUsdc = await airdrop.setConetTreasuryAndUsdc(treasuryAddress, conetUsdc);
  await txUsdc.wait();
  console.log("[4] BUnitAirdrop.setConetTreasuryAndUsdc ok");

  const gbPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  if (fs.existsSync(gbPath)) {
    const gbAddr = JSON.parse(fs.readFileSync(gbPath, "utf-8")).ConetGB1155 as string | undefined;
    if (gbAddr) {
      const currentGb = await treasury.conetGB();
      if (currentGb.toLowerCase() !== gbAddr.toLowerCase()) {
        const txGb = await treasury.setConetGB(gbAddr);
        await txGb.wait();
        console.log("[5] ConetTreasury.setConetGB:", gbAddr);
      }
    }
  }

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const outPath = path.join(deploymentsDir, "conet-ConetTreasury.json");
  const net = await ethers.provider.getNetwork();
  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    deployer: signer.address,
    timestamp: new Date().toISOString(),
    create2: true,
    contracts: {
      ConetTreasury: {
        address: treasuryAddress,
        minerCount: (await treasury.minerCount()).toString(),
        conetUsdc,
        bUnitAirdrop: airdropAddress,
      },
    },
  };
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);

  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  const addrData = fs.existsSync(addrPath)
    ? JSON.parse(fs.readFileSync(addrPath, "utf-8"))
    : { _comment: "CoNET mainnet 合约地址权威配置", network: "conet", chainId: "224422" };
  addrData.ConetTreasury = treasuryAddress;
  addrData.conetUsdc = conetUsdc;
  fs.writeFileSync(addrPath, JSON.stringify(addrData, null, 2) + "\n", "utf-8");
  console.log("updated conet-addresses.json");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
