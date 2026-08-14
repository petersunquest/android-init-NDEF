/**
 * Deploy TreasuryCanonicalERC20V3 test token (minter = TreasuryBridgeV3),
 * register 1 TOKEN : 5 GB on DeveloperTokenFxRegistry, exercise mint/burn FX.
 *
 * Uses **latest** CoNET treasury only:
 *   TreasuryBridgeV3  0xa208982212978550594A7FEEB70a61665d129003
 * Old ConetTreasury / factory createERC20 are deprecated and must not be used.
 *
 * Rate: gbPerFullToken = 5e9  →  1.0 TGB5 = 5.0 GB (GBToken 9 decimals).
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/deployAndTestDeveloperFxTokenConet.ts
 */

import fs from "fs";
import path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const RPC = process.env.CONET_RPC_URL?.trim() || "https://rpc1.conet.network";
const MASTER_PATH = path.join(homedir(), ".master.json");
const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const REG_PATH = path.join(__dirname, "..", "deployments", "conet-DeveloperTokenFxRegistry.json");
const SETTLE_PATH = path.join(__dirname, "..", "deployments", "conet-DepinGbSettlement1155.json");
const OUT_PATH = path.join(__dirname, "..", "deployments", "conet-TestDeveloperFxERC20.json");

/** Latest CoNET business treasury (TreasuryBridgeV3). */
const TREASURY_V3 = "0xa208982212978550594A7FEEB70a61665d129003";
const DEFAULT_GB = "0xC3EF02DaE632b4C10abB66e07d92a387c10838D8";

/** 1 full token → 5 GB (min-units, 9 decimals). */
const GB_PER_FULL_TOKEN = 5n * 10n ** 9n;
const ONE_TOKEN = 10n ** 18n;
const FIVE_GB = 5n * 10n ** 9n;

const BURN_ROLE = ethers.id("BURN_ROLE");
const TREASURY_ROLE = ethers.id("TREASURY_ROLE");

function loadJson(p: string): Record<string, unknown> {
  if (!fs.existsSync(p)) return {};
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

function loadAdminPk(): string {
  if (!fs.existsSync(MASTER_PATH)) throw new Error(`Missing ${MASTER_PATH}`);
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const pk = (data?.settle_contractAdmin || [])[0];
  if (!pk) throw new Error("settle_contractAdmin[0] missing");
  return String(pk).startsWith("0x") ? pk : `0x${pk}`;
}

function loadArtifact(name: string): { abi: unknown[]; bytecode: string } {
  const candidates = [
    path.join(__dirname, "..", "artifacts", "src", "b-unit", `${name}.sol`, `${name}.json`),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      const j = JSON.parse(fs.readFileSync(p, "utf-8"));
      return { abi: j.abi, bytecode: j.bytecode };
    }
  }
  throw new Error(`Artifact not found for ${name}; run npm run compile`);
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const net = await provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`Expected chainId 224422, got ${net.chainId}`);

  const wallet = new ethers.Wallet(loadAdminPk(), provider);
  const regJson = loadJson(REG_PATH) as { proxy?: string };
  const settleJson = loadJson(SETTLE_PATH) as { proxy?: string };
  const addresses = loadJson(ADDRESSES_PATH);

  const treasuryV3 =
    (addresses.TreasuryBridgeV3 as string) ||
    (addresses.ConetTreasury as string) ||
    TREASURY_V3;
  if (treasuryV3.toLowerCase() !== TREASURY_V3.toLowerCase()) {
    throw new Error(`Unexpected treasury ${treasuryV3}; expected TreasuryBridgeV3 ${TREASURY_V3}`);
  }
  // Refuse deprecated legacy treasury address
  if (treasuryV3.toLowerCase() === "0xa7fb50fe8e09e17e74081014d49f4e80729cca48") {
    throw new Error("Refusing deprecated ConetTreasury 0xA7fb50…");
  }

  const registryAddr =
    process.env.FX_REGISTRY?.trim() ||
    regJson.proxy ||
    (addresses.DeveloperTokenFxRegistry as string);
  const settlementAddr =
    process.env.SETTLEMENT_PROXY?.trim() ||
    settleJson.proxy ||
    (addresses.DepinGbSettlement1155 as string);
  const gbAddr =
    process.env.GB_TOKEN_ERC20?.trim() ||
    (addresses.GBToken as string) ||
    DEFAULT_GB;

  if (!registryAddr || !settlementAddr) throw new Error("Missing FX registry or settlement address");

  console.log("=".repeat(60));
  console.log("Deploy Canonical test ERC20 via TreasuryBridgeV3 + 1:5 GB FX");
  console.log("=".repeat(60));
  console.log("signer:", wallet.address);
  console.log("treasuryV3:", treasuryV3);
  console.log("registry:", registryAddr);
  console.log("settlement:", settlementAddr);
  console.log("gbToken:", gbAddr);
  console.log("rate: 1 TOKEN = 5 GB");

  // Confirm treasury has code
  const code = await provider.getCode(treasuryV3);
  if (!code || code === "0x") throw new Error(`Treasury V3 has no code at ${treasuryV3}`);

  const implArt = loadArtifact("TreasuryCanonicalERC20V3");
  const proxyArt = loadArtifact("TreasuryV3ERC1967Proxy");

  const Impl = new ethers.ContractFactory(implArt.abi as ethers.InterfaceAbi, implArt.bytecode, wallet);
  const impl = await Impl.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  console.log("[1] TreasuryCanonicalERC20V3 impl:", implAddr);

  const initData = Impl.interface.encodeFunctionData("initialize", [
    "Test Developer FX 1:5",
    "TGB5",
    18,
    wallet.address,
    treasuryV3,
    "https://beamio.app/api/metadata/test-developer-fx-1-5.json",
  ]);

  const Proxy = new ethers.ContractFactory(
    proxyArt.abi as ethers.InterfaceAbi,
    proxyArt.bytecode,
    wallet,
  );
  const proxy = await Proxy.deploy(implAddr, initData);
  await proxy.waitForDeployment();
  const tokenAddr = await proxy.getAddress();
  console.log("[2] TGB5 proxy (Canonical V3):", tokenAddr);

  const token = new ethers.Contract(
    tokenAddr,
    [
      "function setTreasury(address)",
      "function setBurner(address)",
      "function revokeBurner(address)",
      "function hasRole(bytes32,address) view returns (bool)",
      "function mint(address,uint256)",
      "function burnFrom(address,uint256)",
      "function balanceOf(address) view returns (uint256)",
      "function decimals() view returns (uint8)",
      "function symbol() view returns (string)",
    ],
    wallet,
  );

  // Mint: only treasury (BRIDGE from initialize + TREASURY_ROLE). Never grant mint to Registry/EOA.
  const txSetTreasury = await token.setTreasury(treasuryV3);
  await txSetTreasury.wait();
  console.log("[3] setTreasury(TreasuryBridgeV3) ok — sole Canonical minter with bridge");

  // FX registry: BURN_ROLE only (settle burns). GB→Canonical mint goes via treasury.mintDeveloperFxFromRegistry.
  const txBurner = await token.setBurner(registryAddr);
  await txBurner.wait();
  console.log("[4] setBurner(FX registry) ok — burn-only, no mint");

  // Bootstrap inventory: mint through treasury offline path is preferred in prod.
  // Test shortcut: temporary burner is NOT mint — use treasury executeTreasuryAssetOp or payAndMint.
  // Here we call mint as treasury via impersonation is unavailable; deploy script uses
  // executeTreasuryAssetOpWithSignature or direct mint only if wallet==treasury owner with role.
  // DEFAULT_ADMIN is deployer but mint requires TREASURY_ROLE — mint via treasury contract:
  const treasuryC = new ethers.Contract(
    treasuryV3,
    [
      "function setTreasuryAssetKind(address,uint8)",
      "function executeTreasuryAssetOpWithSignature(address,address,uint8,address,uint256,uint256,uint256,bytes)",
      "function treasuryAssetOpNonces(address) view returns (uint256)",
      "function getTreasuryAssetOpDigest(address,address,uint8,address,uint256,uint256,uint256) view returns (bytes32)",
    ],
    wallet,
  );
  // Kind Canonical = 1
  const kindTx = await treasuryC.setTreasuryAssetKind(tokenAddr, 1);
  await kindTx.wait();
  const mintAmt = 10n * ONE_TOKEN;
  const nonce = await treasuryC.treasuryAssetOpNonces(wallet.address);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  // op Mint = 0; digest is already EIP-712 typed-data hash
  const digest = await treasuryC.getTreasuryAssetOpDigest(
    wallet.address,
    tokenAddr,
    0,
    wallet.address,
    mintAmt,
    nonce,
    deadline,
  );
  const opSig = ethers.Signature.from(wallet.signingKey.sign(digest)).serialized;
  const mintViaTre = await treasuryC.executeTreasuryAssetOpWithSignature(
    wallet.address,
    tokenAddr,
    0,
    wallet.address,
    mintAmt,
    nonce,
    deadline,
    opSig,
  );
  await mintViaTre.wait();
  console.log("[5] mint 10 TGB5 via treasury executeTreasuryAssetOp (not EOA TREASURY_ROLE) ok");

  const registry = new ethers.Contract(
    registryAddr,
    [
      "function admins(address) view returns (bool)",
      "function registerToken(address token, address developer, uint256 gbPerFullToken, bool enabled)",
      "function tokens(address) view returns (bool exists, bool enabled, uint8 tokenDecimals, uint256 gbPerFullToken, address developer)",
      "function quoteTokenIn(address token, uint256 gbAmount) view returns (uint256)",
      "function quoteGbOut(address token, uint256 tokenAmount) view returns (uint256)",
      "function burnDeveloperMintGbToSettlement(address user, address token, uint256 gbAmount) returns (uint256)",
      "function burnGbMintDeveloper(address user, address token, uint256 gbAmount) returns (uint256)",
    ],
    wallet,
  );

  if (!(await registry.admins(wallet.address))) {
    throw new Error(`signer ${wallet.address} is not FX registry admin`);
  }

  const txReg = await registry.registerToken(tokenAddr, wallet.address, GB_PER_FULL_TOKEN, true);
  await txReg.wait();
  console.log("[6] registerToken 1:5 ok", txReg.hash);

  const cfg = await registry.tokens(tokenAddr);
  console.log(
    "    exists=%s enabled=%s decimals=%s gbPerFullToken=%s",
    cfg.exists,
    cfg.enabled,
    cfg.tokenDecimals,
    cfg.gbPerFullToken.toString(),
  );

  const qIn = await registry.quoteTokenIn(tokenAddr, FIVE_GB);
  const qOut = await registry.quoteGbOut(tokenAddr, ONE_TOKEN);
  console.log("[7] quoteTokenIn(5 GB)=%s quoteGbOut(1 TOKEN)=%s", qIn.toString(), qOut.toString());
  if (qIn !== ONE_TOKEN) throw new Error(`quoteTokenIn mismatch: ${qIn}`);
  if (qOut !== FIVE_GB) throw new Error(`quoteGbOut mismatch: ${qOut}`);

  const gb = new ethers.Contract(
    gbAddr,
    [
      "function balanceOfAll(address) view returns (uint256 total, uint256 free, uint256 paid)",
      "function mintPaid(address to, uint256 amount)",
      "function admins(address) view returns (bool)",
    ],
    wallet,
  );

  const settleBefore = await gb.balanceOfAll(settlementAddr);
  const tokBefore = await token.balanceOf(wallet.address);
  console.log(
    "[8] before FX settlement.paid=%s token=%s",
    settleBefore.paid.toString(),
    ethers.formatEther(tokBefore),
  );

  // Forward: registry burnFrom (role) → mintPaid GB to Settlement
  const txFwd = await registry.burnDeveloperMintGbToSettlement(wallet.address, tokenAddr, FIVE_GB);
  const rcFwd = await txFwd.wait();
  console.log("[9] burnDeveloperMintGbToSettlement tx", txFwd.hash, "status", rcFwd?.status);

  const settleMid = await gb.balanceOfAll(settlementAddr);
  const tokMid = await token.balanceOf(wallet.address);
  const paidDelta = settleMid.paid - settleBefore.paid;
  const tokBurned = tokBefore - tokMid;
  console.log("    settlement.paid delta=%s tokenBurned=%s", paidDelta.toString(), tokBurned.toString());
  if (paidDelta !== FIVE_GB) throw new Error(`settlement paid delta ${paidDelta}`);
  if (tokBurned !== ONE_TOKEN) throw new Error(`token burned ${tokBurned}`);

  // Reverse: seed paid GB then burnGbMintDeveloper → treasury.mintDeveloperFxFromRegistry
  if (!(await gb.admins(wallet.address))) {
    throw new Error("signer is not GBToken admin; cannot seed paid GB for reverse test");
  }
  const txSeed = await gb.mintPaid(wallet.address, FIVE_GB);
  await txSeed.wait();
  console.log("[10] mintPaid 5 GB to user (seed reverse) ok");

  const tokBeforeRev = await token.balanceOf(wallet.address);
  const userPaidBefore = (await gb.balanceOfAll(wallet.address)).paid;
  const txRev = await registry.burnGbMintDeveloper(wallet.address, tokenAddr, FIVE_GB);
  const rcRev = await txRev.wait();
  console.log("[11] burnGbMintDeveloper tx", txRev.hash, "status", rcRev?.status);

  const tokMinted = (await token.balanceOf(wallet.address)) - tokBeforeRev;
  const paidBurned = userPaidBefore - (await gb.balanceOfAll(wallet.address)).paid;
  console.log("    tokenMinted=%s paidBurned=%s", tokMinted.toString(), paidBurned.toString());
  if (tokMinted !== ONE_TOKEN) throw new Error(`token minted ${tokMinted}`);
  if (paidBurned !== FIVE_GB) throw new Error(`paid burned ${paidBurned}`);

  const out = {
    network: "conet",
    chainId: "224422",
    timestamp: new Date().toISOString(),
    deployer: wallet.address,
    treasury: treasuryV3,
    treasuryKind: "TreasuryBridgeV3",
    token: tokenAddr,
    tokenImpl: implAddr,
    tokenKind: "TreasuryCanonicalERC20V3",
    name: "Test Developer FX 1:5",
    symbol: "TGB5",
    decimals: 18,
    gbPerFullToken: GB_PER_FULL_TOKEN.toString(),
    rate: "1 TOKEN = 5 GB",
    registry: registryAddr,
    settlement: settlementAddr,
    gbToken: gbAddr,
    deprecatedNotUsed: {
      ConetTreasury_legacy: "0xA7fb50fE8e09E17E74081014d49f4E80729cCA48",
    },
    tests: {
      quoteOk: true,
      forwardBurnDeveloperMintGb: { tx: txFwd.hash, gb: FIVE_GB.toString(), tokenBurned: ONE_TOKEN.toString() },
      reverseBurnGbMintDeveloper: { tx: txRev.hash, gb: FIVE_GB.toString(), tokenMinted: ONE_TOKEN.toString() },
    },
  };
  fs.writeFileSync(OUT_PATH, JSON.stringify(out, null, 2));
  console.log("[12] wrote", OUT_PATH);

  addresses.TestDeveloperFxERC20 = tokenAddr;
  addresses.TestDeveloperFxERC20Impl = implAddr;
  addresses.TreasuryBridgeV3 = treasuryV3;
  addresses.ConetTreasury = treasuryV3;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n");
  console.log("[13] updated conet-addresses.json");

  console.log("=".repeat(60));
  console.log("ALL FX TESTS PASSED (Treasury V3 Canonical + 1:5 mint/burn)");
  console.log("=".repeat(60));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
