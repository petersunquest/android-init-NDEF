/**
 * 以 Treasury 工厂登记为唯一标准：createERC20 新 USDC，并全栈改指向。
 *
 * 1. ConetTreasury.createERC20("USD Coin","USDC",6, Base Circle USDC)
 * 2. BUnitAirdropV2.setConfig / ReferralRegistryVaultV1.setConfig
 * 3. ConetTreasuryPeer.setUsdcErc20 + registerCanonicalErc20Peer(Base Circle)
 * 4. Base Peer：registerCanonicalErc20Peer(CoNET, newUsdc)（跨链入站映射）
 * 5. 更新 deployments/conet-addresses.json 等
 *
 * 运行: npx hardhat run scripts/createFactoryConetUsdcAndRetarget.ts --network conet
 * 可选: SKIP_BASE_PEER=1 跳过 Base 登记
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { JsonRpcProvider, Wallet, Contract } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const BASE_CHAIN_ID = 8453n;
const CONET_CHAIN_ID = 224422n;
const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const TREASURY_JSON_PATH = path.join(__dirname, "..", "deployments", "conet-ConetTreasury.json");
const META_JSON_PATH = path.join(__dirname, "..", "deployments", "conet-factory-usdc.json");
const USDC_META_ASSET = path.join(
  __dirname,
  "..",
  "deployments",
  "assets",
  "usdc",
  "erc20",
  "metadata.json"
);

const PEER_ABI = [
  "function setUsdcErc20(address) external",
  "function usdcErc20() view returns (address)",
  "function CANONICAL_USDC_ERC20() view returns (uint8)",
  "function registerCanonicalErc20Peer(uint256,address,uint8,string,string,uint8) external returns (uint8)",
  "function canonicalErc20Kind(uint256,address) view returns (uint8)",
];

async function main() {
  const addrs = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"));
  const treasuryAddr = addrs.ConetTreasury as string;
  const peerAddr = addrs.ConetTreasuryPeer as string;
  const airdropV2 = addrs.BUnitAirdropV2 as string;
  const registry = addrs.ReferralRegistryVaultV1 as string;
  const bunit = addrs.BUint as string;
  const oldUsdc = addrs.conetUsdc as string;
  const bizKet = addrs.BusinessStartKet as string;
  const cardFactory = addrs.CARD_FACTORY as string;

  if (!treasuryAddr || !peerAddr || !airdropV2 || !registry || !bunit) {
    throw new Error("conet-addresses.json missing Treasury/Peer/AirdropV2/Registry/BUint");
  }

  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("no signer (check ~/.master.json settle_contractAdmin / beamio_Admins)");

  console.log("=".repeat(60));
  console.log("createERC20 factory USDC + retarget stack");
  console.log("=".repeat(60));
  console.log("signer:", signer.address);
  console.log("Treasury:", treasuryAddr);
  console.log("Peer:", peerAddr);
  console.log("old conetUsdc:", oldUsdc);

  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddr);
  const isMiner = await treasury.isMiner(signer.address);
  if (!isMiner) throw new Error(`signer ${signer.address} is not Treasury miner`);

  // 1) createERC20
  const before = (await treasury.getCreatedTokens()) as string[];
  const txCreate = await treasury.createERC20("USD Coin", "USDC", 6, BASE_USDC);
  const receiptCreate = await txCreate.wait();
  const after = (await treasury.getCreatedTokens()) as string[];
  const newUsdc = after.find(
    (t) => !before.map((x) => x.toLowerCase()).includes(t.toLowerCase())
  );
  if (!newUsdc) {
    // fallback: last entry
    const last = after[after.length - 1];
    if (!last || before.map((x) => x.toLowerCase()).includes(last.toLowerCase())) {
      throw new Error("createERC20 succeeded but could not resolve new token address");
    }
  }
  const factoryUsdc = ethers.getAddress(newUsdc ?? after[after.length - 1]!);
  const inList = await treasury.isCreatedToken(factoryUsdc);
  console.log("[1] createERC20 tx:", receiptCreate?.hash);
  console.log("[1] new factory USDC:", factoryUsdc, "isCreatedToken:", inList);
  if (!inList) throw new Error("new USDC not in _isCreatedToken");

  // 2) Airdrop V2
  const airdrop = await ethers.getContractAt("BUnitAirdropV2", airdropV2);
  const airdropOwner = await airdrop.owner();
  if (airdropOwner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`AirdropV2 owner ${airdropOwner} != signer ${signer.address}`);
  }
  const curB = await airdrop.bunit();
  const curT = await airdrop.conetTreasury();
  const curR = await airdrop.referralSettlement();
  const txA = await airdrop.setConfig(curB, curT, factoryUsdc, curR);
  await txA.wait();
  console.log("[2] AirdropV2.setConfig conetUsdc →", factoryUsdc, "tx:", txA.hash);

  // 3) Referral registry
  const reg = await ethers.getContractAt("ReferralRegistryVaultV1", registry);
  const regOwner = await reg.owner();
  if (regOwner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Registry owner ${regOwner} != signer`);
  }
  const ket = bizKet || (await reg.businessStartKet());
  const drop = await reg.bunitAirdrop();
  const factory = cardFactory || (await reg.userCardFactory());
  const txR = await reg.setConfig(ket, drop, factory, factoryUsdc);
  await txR.wait();
  console.log("[3] ReferralRegistry.setConfig conetUsdc →", factoryUsdc, "tx:", txR.hash);

  // 4) CoNET Peer
  const peer = await ethers.getContractAt("ConetTreasuryPeer", peerAddr);
  const txP = await peer.setUsdcErc20(factoryUsdc);
  await txP.wait();
  console.log("[4] Peer.setUsdcErc20 →", factoryUsdc, "tx:", txP.hash);

  const kindUsdc = await peer.CANONICAL_USDC_ERC20();
  const existingKind = await peer.canonicalErc20Kind(BASE_CHAIN_ID, BASE_USDC);
  if (Number(existingKind) !== Number(kindUsdc)) {
    const txReg = await peer.registerCanonicalErc20Peer(
      BASE_CHAIN_ID,
      BASE_USDC,
      kindUsdc,
      "USD Coin",
      "USDC",
      6
    );
    await txReg.wait();
    console.log("[4b] registerCanonicalErc20Peer(Base Circle) tx:", txReg.hash);
  } else {
    console.log("[4b] Base Circle already canonical kind", existingKind.toString());
  }

  // 5) Base Peer: map CoNET factory USDC → USDC kind (for inbound bridge votes)
  if (process.env.SKIP_BASE_PEER !== "1") {
    const baseRpc =
      process.env.BASE_RPC_URL?.trim() ||
      process.env.BASE_RPC?.trim() ||
      "https://base-rpc.conet.network";
    const pk = (signer as { privateKey?: string }).privateKey;
    if (!pk) {
      console.warn("[5] skip Base Peer: signer has no privateKey export");
    } else {
      const baseProvider = new JsonRpcProvider(baseRpc, 8453);
      const baseWallet = new Wallet(pk, baseProvider);
      const basePeer = new Contract(peerAddr, PEER_ABI, baseWallet);
      const baseKind = await basePeer.CANONICAL_USDC_ERC20();
      const mapped = await basePeer.canonicalErc20Kind(CONET_CHAIN_ID, factoryUsdc);
      if (Number(mapped) !== Number(baseKind)) {
        const txB = await basePeer.registerCanonicalErc20Peer(
          CONET_CHAIN_ID,
          factoryUsdc,
          baseKind,
          "USD Coin",
          "USDC",
          6
        );
        await txB.wait();
        console.log("[5] Base Peer registerCanonicalErc20Peer(new USDC) tx:", txB.hash);
      } else {
        console.log("[5] Base Peer already maps new USDC");
      }
      // Optionally clear F924 mapping is not required; unused peer token stays stale.
    }
  } else {
    console.log("[5] SKIP_BASE_PEER=1");
  }

  // 6) Persist addresses
  const dep = Array.isArray(addrs.DEPRECATED_CONET_USDC) ? [...addrs.DEPRECATED_CONET_USDC] : [];
  if (oldUsdc && !dep.map((x: string) => x.toLowerCase()).includes(oldUsdc.toLowerCase())) {
    dep.push(oldUsdc);
  }
  addrs.conetUsdc = factoryUsdc;
  addrs.DEPRECATED_CONET_USDC = dep;
  addrs.ConetUsdcDeployMode = "Treasury_createERC20_factory_registered";
  addrs.ConetUsdcIconUrl = "https://mainnet.conet.network/usdc/erc20/USDC-256.png";
  addrs.ConetUsdcMetadataUrl = "https://mainnet.conet.network/usdc/erc20/metadata.json";
  delete addrs.ConetUsdcUupsImpl;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addrs, null, 2) + "\n");

  const treasuryData = fs.existsSync(TREASURY_JSON_PATH)
    ? JSON.parse(fs.readFileSync(TREASURY_JSON_PATH, "utf-8"))
    : { network: "conet", chainId: "224422", contracts: { ConetTreasury: {} } };
  treasuryData.contracts ??= {};
  treasuryData.contracts.ConetTreasury ??= {};
  treasuryData.contracts.ConetTreasury.address = treasuryAddr;
  treasuryData.contracts.ConetTreasury.conetUsdc = factoryUsdc;
  treasuryData.contracts.ConetTreasury.bUnitAirdrop = airdropV2;
  treasuryData.contracts.ConetTreasury.peer = peerAddr;
  fs.writeFileSync(TREASURY_JSON_PATH, JSON.stringify(treasuryData, null, 2) + "\n");

  const meta = {
    network: "conet",
    chainId: "224422",
    createdAt: new Date().toISOString(),
    createTx: receiptCreate?.hash,
    treasury: treasuryAddr,
    peer: peerAddr,
    factoryUsdc,
    previousUsdc: oldUsdc,
    name: "USD Coin",
    symbol: "USDC",
    decimals: 6,
    baseToken: BASE_USDC,
    iconUrl: "https://mainnet.conet.network/usdc/erc20/USDC-256.png",
    metadataUrl: "https://mainnet.conet.network/usdc/erc20/metadata.json",
    explorer: `https://mainnet.conet.network/token/${factoryUsdc}`,
  };
  fs.writeFileSync(META_JSON_PATH, JSON.stringify(meta, null, 2) + "\n");

  if (fs.existsSync(USDC_META_ASSET)) {
    const assetMeta = JSON.parse(fs.readFileSync(USDC_META_ASSET, "utf-8"));
    assetMeta.name = "USD Coin";
    assetMeta.symbol = "USDC";
    assetMeta.decimals = 6;
    assetMeta.image = "https://mainnet.conet.network/usdc/erc20/USDC.png";
    assetMeta.links = assetMeta.links || {};
    assetMeta.links.explorer_conet = `https://mainnet.conet.network/token/${factoryUsdc}`;
    fs.writeFileSync(USDC_META_ASSET, JSON.stringify(assetMeta, null, 2) + "\n");
  }

  console.log("\n✅ factory USDC ready:", factoryUsdc);
  console.log("Next:");
  console.log("  bash scripts/deployConetUsdcAssets.sh");
  console.log(`  CONET_USDC_ADDRESS=${factoryUsdc} bash scripts/registerConetUsdcBlockscoutConet.sh`);
  console.log("  npx tsx scripts/updateConetReferences.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
