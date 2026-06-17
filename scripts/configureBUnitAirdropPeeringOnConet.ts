/**
 * 将已部署的 BUnitAirdrop 与 publicrpc CoNET 权威地址对齐：
 * - BeamioIndexerDiamond.setAdmin(BUnitAirdrop)
 * - BUnitAirdrop.setBeamioIndexerDiamond / setConetTreasuryAndUsdc / setQuoteHelper
 * - ConetTreasury.setBUnitAirdrop
 * - BUnitAirdrop.addAdmin(ConetTreasury)（consumeFromUser 需 Treasury 为 admin）
 *
 * 运行: npx hardhat run scripts/configureBUnitAirdropPeeringOnConet.ts --network conet
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const INDEXER_PATH = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
const MASTER_PATH = path.join(homedir(), ".master.json");

async function main() {
  if (!fs.existsSync(ADDRESSES_PATH)) throw new Error("缺少 conet-addresses.json");
  const addrs = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const airdropAddr = addrs.BUnitAirdrop as string;
  const treasuryAddr = addrs.ConetTreasury as string;
  const usdcAddr = addrs.conetUsdc as string;
  const indexerAddr = addrs.BeamioIndexerDiamond as string;
  const quoteHelper = addrs.beamioQuoteHelperV07 as string;

  if (!airdropAddr || !treasuryAddr || !usdcAddr || !indexerAddr || !quoteHelper) {
    throw new Error("conet-addresses.json 缺少 BUnitAirdrop / ConetTreasury / conetUsdc / BeamioIndexerDiamond / beamioQuoteHelperV07");
  }

  if (!fs.existsSync(INDEXER_PATH)) throw new Error("缺少 conet-IndexerDiamond.json");
  const indexerDeploy = JSON.parse(fs.readFileSync(INDEXER_PATH, "utf-8"));
  if (indexerDeploy.diamond?.toLowerCase() !== indexerAddr.toLowerCase()) {
    throw new Error(`Indexer diamond 不一致: json=${indexerDeploy.diamond} addresses=${indexerAddr}`);
  }

  const master = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const pk = master?.settle_contractAdmin?.[0];
  if (!pk) throw new Error("~/.master.json settle_contractAdmin[0] 为空");

  const { ethers } = await networkModule.connect();
  const signer = new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`, ethers.provider);
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("Configure BUnitAirdrop peering on CoNET");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("signer:", signer.address);
  console.log("BUnitAirdrop:", airdropAddr);
  console.log("BeamioIndexerDiamond:", indexerAddr);
  console.log("ConetTreasury:", treasuryAddr);
  console.log("conetUsdc:", usdcAddr);
  console.log("beamioQuoteHelperV07:", quoteHelper);

  const airdrop = (await ethers.getContractAt("BUnitAirdrop", airdropAddr)).connect(signer);
  const treasury = (await ethers.getContractAt("ConetTreasury", treasuryAddr)).connect(signer);
  const diamond = await ethers.getContractAt(
    ["function setAdmin(address admin, bool enabled) external", "function isAdmin(address) view returns (bool)", "function owner() view returns (address)"],
    indexerAddr,
    signer
  );

  const owner = await airdrop.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`signer ${signer.address} 不是 BUnitAirdrop owner (${owner})`);
  }

  // 1. Indexer.setAdmin(BUnitAirdrop, true)
  const diamondOwner = await diamond.owner();
  if (diamondOwner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`signer 不是 Indexer owner (${diamondOwner})`);
  }
  if (!(await diamond.isAdmin(airdropAddr))) {
    const tx = await diamond.setAdmin(airdropAddr, true);
    await tx.wait();
    console.log("[1] BeamioIndexerDiamond.setAdmin(BUnitAirdrop, true) ok | tx:", tx.hash);
  } else {
    console.log("[1] BUnitAirdrop 已是 Indexer admin，跳过");
  }

  // 2. setBeamioIndexerDiamond
  const curIndexer = await airdrop.beamioIndexerDiamond();
  if (curIndexer.toLowerCase() !== indexerAddr.toLowerCase()) {
    const tx = await airdrop.setBeamioIndexerDiamond(indexerAddr);
    await tx.wait();
    console.log("[2] setBeamioIndexerDiamond ok | tx:", tx.hash);
  } else {
    console.log("[2] beamioIndexerDiamond 已正确，跳过");
  }

  // 3. setConetTreasuryAndUsdc
  const curTreasury = await airdrop.conetTreasury();
  const curUsdc = await airdrop.conetUsdc();
  if (
    curTreasury.toLowerCase() !== treasuryAddr.toLowerCase() ||
    curUsdc.toLowerCase() !== usdcAddr.toLowerCase()
  ) {
    const tx = await airdrop.setConetTreasuryAndUsdc(treasuryAddr, usdcAddr);
    await tx.wait();
    console.log("[3] setConetTreasuryAndUsdc ok | tx:", tx.hash);
  } else {
    console.log("[3] conetTreasury + conetUsdc 已正确，跳过");
  }

  // 4. setQuoteHelper
  const curQh = await airdrop.quoteHelper();
  if (curQh.toLowerCase() !== quoteHelper.toLowerCase()) {
    const tx = await airdrop.setQuoteHelper(quoteHelper);
    await tx.wait();
    console.log("[4] setQuoteHelper ok | tx:", tx.hash);
  } else {
    console.log("[4] quoteHelper 已正确，跳过");
  }

  // 5. BUnitAirdrop.addAdmin(ConetTreasury)
  if (!(await airdrop.admins(treasuryAddr))) {
    const tx = await airdrop.addAdmin(treasuryAddr);
    await tx.wait();
    console.log("[5] addAdmin(ConetTreasury) ok | tx:", tx.hash);
  } else {
    console.log("[5] ConetTreasury 已是 BUnitAirdrop admin，跳过");
  }

  // 6. ConetTreasury.setBUnitAirdrop
  const treasuryAbi = [
    "function bunitAirdrop() view returns (address)",
    "function isMiner(address) view returns (bool)",
    "function setBUnitAirdrop(address) external",
  ];
  const treasuryRead = new ethers.Contract(treasuryAddr, treasuryAbi, ethers.provider);
  const curAirdropOnTreasury = await treasuryRead.bunitAirdrop();
  if (curAirdropOnTreasury.toLowerCase() !== airdropAddr.toLowerCase()) {
    const isMiner = await treasuryRead.isMiner(signer.address);
    if (!isMiner) throw new Error(`signer 不是 ConetTreasury miner，无法 setBUnitAirdrop`);
    const tx = await treasury.setBUnitAirdrop(airdropAddr);
    await tx.wait();
    console.log("[6] ConetTreasury.setBUnitAirdrop ok | tx:", tx.hash);
  } else {
    console.log("[6] ConetTreasury.bunitAirdrop 已正确，跳过");
  }

  // 校验
  console.log("\n--- 链上校验 ---");
  console.log("beamioIndexerDiamond:", await airdrop.beamioIndexerDiamond());
  console.log("conetTreasury:", await airdrop.conetTreasury());
  console.log("conetUsdc:", await airdrop.conetUsdc());
  console.log("quoteHelper:", await airdrop.quoteHelper());
  console.log("Indexer.isAdmin(airdrop):", await diamond.isAdmin(airdropAddr));
  console.log("airdrop.admins(treasury):", await airdrop.admins(treasuryAddr));
  console.log("treasury.bunitAirdrop:", await treasuryRead.bunitAirdrop());

  console.log("\n✅ BUnitAirdrop 配置完成");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
