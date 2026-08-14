/**
 * Register TGB5 on DeveloperTokenFxRegistry (1:5), configure PayByUse NFT#5 on
 * DepinGbSettlement1155, upgrade settlement for whole-token burn + developer surplus GB.
 *
 * Product:
 *   User holds APP NFT#5 → CoNET settle prefers burn TGB5 → mint GB.
 *   Whole-token FX (1 TGB5 = 5 GB): miner gets usage GB; APP developer gets surplus.
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/registerTgb5PayByUsePassConet.ts
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
const TGB5_PATH = path.join(__dirname, "..", "deployments", "conet-TestDeveloperFxERC20.json");
const SETTLE_PATH = path.join(__dirname, "..", "deployments", "conet-DepinGbSettlement1155.json");
const OUT_PATH = path.join(__dirname, "..", "deployments", "conet-TGB5-PayByUsePass.json");

const TGB5_DEFAULT = "0xEb8c8b0f4e3f779D8A8d863580AaaD72AFebe242";
const REG_DEFAULT = "0x3B00a3F7341C0449e7a3D6e466f85F6F39dFf6e0";
const SETTLE_DEFAULT = "0x06cf5bF56DF3E327FB30214E001A67456aaBB287";
const GB_DEFAULT = "0xC3EF02DaE632b4C10abB66e07d92a387c10838D8";

/** TGB5 PayByUse series id (APP tag NFT#). */
const PASS_TOKEN_ID = BigInt(process.env.TGB5_PASS_TOKEN_ID?.trim() || "5");
const PASS_KIND_PAY_BY_USE = 2;
/** ~ year 2100 */
const EXPIRES_AT = BigInt(process.env.TGB5_PASS_EXPIRES?.trim() || "4102444800");
/** 1 full TGB5 → 5 GB (9 decimals). */
const GB_PER_FULL_TOKEN = 5n * 10n ** 9n;

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

function loadArtifact(solFile: string, name: string): { abi: unknown[]; bytecode: string } {
  const p = path.join(__dirname, "..", "artifacts", "src", "b-unit", solFile, `${name}.json`);
  if (!fs.existsSync(p)) throw new Error(`Missing artifact ${p}; run npm run compile`);
  const j = JSON.parse(fs.readFileSync(p, "utf-8"));
  return { abi: j.abi, bytecode: j.bytecode };
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const net = await provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`Expected 224422, got ${net.chainId}`);

  const wallet = new ethers.Wallet(loadAdminPk(), provider);
  const addresses = loadJson(ADDRESSES_PATH);
  const tgb5Json = loadJson(TGB5_PATH) as { token?: string; registry?: string; settlement?: string };
  const settleJson = loadJson(SETTLE_PATH) as { proxy?: string; implementation?: string };

  const tgb5 = (process.env.TGB5?.trim() || tgb5Json.token || addresses.TestDeveloperFxERC20 || TGB5_DEFAULT) as string;
  const registryAddr = (process.env.FX_REGISTRY?.trim() || tgb5Json.registry || addresses.DeveloperTokenFxRegistry || REG_DEFAULT) as string;
  const settlementAddr = (process.env.SETTLEMENT_PROXY?.trim() || settleJson.proxy || addresses.DepinGbSettlement1155 || SETTLE_DEFAULT) as string;
  const gbAddr = (process.env.GB_TOKEN_ERC20?.trim() || addresses.GBToken || GB_DEFAULT) as string;

  /** APP developer = TGB5 issuer (registry developer / pass developer). */
  const developer = (process.env.TGB5_DEVELOPER?.trim() || wallet.address) as string;

  console.log("=".repeat(60));
  console.log("Register TGB5 + PayByUse NFT# + surplus settlement upgrade");
  console.log("=".repeat(60));
  console.log("signer:", wallet.address);
  console.log("developer:", developer);
  console.log("TGB5:", tgb5);
  console.log("registry:", registryAddr);
  console.log("settlement:", settlementAddr);
  console.log("passTokenId:", PASS_TOKEN_ID.toString());
  console.log("rate: 1 TGB5 = 5 GB");

  // ---- 1) Upgrade Settlement impl (whole-token surplus) ----
  const settleArt = loadArtifact("DepinGbSettlement1155.sol", "DepinGbSettlement1155");
  const SettleFactory = new ethers.ContractFactory(settleArt.abi as ethers.InterfaceAbi, settleArt.bytecode, wallet);
  const settleImpl = await SettleFactory.deploy();
  await settleImpl.waitForDeployment();
  const settleImplAddr = await settleImpl.getAddress();
  console.log("[1] new Settlement impl:", settleImplAddr);

  const settlement = new ethers.Contract(
    settlementAddr,
    [
      "function upgradeToAndCall(address,bytes)",
      "function admins(address) view returns (bool)",
      "function developerTokenFxRegistry() view returns (address)",
      "function setDeveloperTokenFxRegistry(address)",
      "function configurePass(uint256,address,uint8,uint64,address)",
      "function passConfig(uint256) view returns (address developer,uint64 expiresAt,uint8 kind,bool exists,address payByUseErc20)",
      "function mintPass(address,uint256,uint256)",
      "function PASS_KIND_PAY_BY_USE() view returns (uint8)",
    ],
    wallet,
  );
  if (!(await settlement.admins(wallet.address))) {
    throw new Error(`signer ${wallet.address} is not settlement admin`);
  }
  const upTx = await settlement.upgradeToAndCall(settleImplAddr, "0x");
  await upTx.wait();
  console.log("[2] settlement upgradeToAndCall", upTx.hash);

  const wiredReg = await settlement.developerTokenFxRegistry();
  if (wiredReg.toLowerCase() !== registryAddr.toLowerCase()) {
    const txWire = await settlement.setDeveloperTokenFxRegistry(registryAddr);
    await txWire.wait();
    console.log("[2b] setDeveloperTokenFxRegistry", txWire.hash);
  } else {
    console.log("[2b] FX registry already wired");
  }

  // ---- 2) Ensure TGB5 registered 1:5 ----
  const registry = new ethers.Contract(
    registryAddr,
    [
      "function admins(address) view returns (bool)",
      "function registerToken(address,address,uint256,bool)",
      "function tokens(address) view returns (bool exists,bool enabled,uint8 tokenDecimals,uint256 gbPerFullToken,address developer)",
      "function settlement() view returns (address)",
    ],
    wallet,
  );
  if (!(await registry.admins(wallet.address))) {
    throw new Error(`signer is not FX registry admin`);
  }

  const before = await registry.tokens(tgb5);
  const txReg = await registry.registerToken(tgb5, developer, GB_PER_FULL_TOKEN, true);
  await txReg.wait();
  const after = await registry.tokens(tgb5);
  console.log("[3] registerToken TGB5 1:5", txReg.hash);
  console.log("    before developer=%s rate=%s", before.developer, before.gbPerFullToken?.toString?.() ?? before[3]?.toString?.());
  console.log(
    "    after exists=%s enabled=%s decimals=%s rate=%s developer=%s",
    after.exists,
    after.enabled,
    after.tokenDecimals,
    after.gbPerFullToken.toString(),
    after.developer,
  );
  if (after.gbPerFullToken !== GB_PER_FULL_TOKEN) throw new Error("rate mismatch");
  if (after.developer.toLowerCase() !== developer.toLowerCase()) throw new Error("developer mismatch");

  // Ensure FX registry can burn TGB5
  const token = new ethers.Contract(
    tgb5,
    [
      "function TREASURY_ROLE() view returns (bytes32)",
      "function hasRole(bytes32,address) view returns (bool)",
      "function grantRole(bytes32,address)",
    ],
    wallet,
  );
  const treasuryRole = await token.TREASURY_ROLE();
  if (!(await token.hasRole(treasuryRole, registryAddr))) {
    const txG = await token.grantRole(treasuryRole, registryAddr);
    await txG.wait();
    console.log("[3b] grant TREASURY_ROLE to FX registry", txG.hash);
  }

  // ---- 3) configurePass NFT# ----
  const kind = Number(await settlement.PASS_KIND_PAY_BY_USE());
  if (kind !== PASS_KIND_PAY_BY_USE) throw new Error(`unexpected PASS_KIND_PAY_BY_USE ${kind}`);

  const txPass = await settlement.configurePass(
    PASS_TOKEN_ID,
    developer,
    PASS_KIND_PAY_BY_USE,
    EXPIRES_AT,
    tgb5,
  );
  await txPass.wait();
  console.log("[4] configurePass NFT#%s PayByUse", PASS_TOKEN_ID.toString(), txPass.hash);

  const pc = await settlement.passConfig(PASS_TOKEN_ID);
  console.log("    passConfig", {
    developer: pc.developer,
    expiresAt: pc.expiresAt.toString(),
    kind: Number(pc.kind),
    exists: pc.exists,
    payByUseErc20: pc.payByUseErc20,
  });
  if (!pc.exists || Number(pc.kind) !== PASS_KIND_PAY_BY_USE) throw new Error("pass not configured");
  if (pc.payByUseErc20.toLowerCase() !== tgb5.toLowerCase()) throw new Error("pass erc20 != TGB5");

  // Mint one pass to developer so they can distribute / self-test (optional seed)
  const txMint = await settlement.mintPass(developer, PASS_TOKEN_ID, 1n);
  await txMint.wait();
  console.log("[5] mintPass x1 to developer", txMint.hash);

  // Persist
  settleJson.implementation = settleImplAddr;
  settleJson.proxy = settlementAddr;
  settleJson.upgradedAt = new Date().toISOString();
  settleJson.developerTokenFxRegistry = registryAddr;
  settleJson.payByUseSurplusUpgrade = {
    note: "Whole-token FX burn; surplus GB → pass developer",
    impl: settleImplAddr,
    upgradeTx: upTx.hash,
  };
  fs.writeFileSync(SETTLE_PATH, JSON.stringify(settleJson, null, 2) + "\n");

  addresses.DepinGbSettlement1155 = settlementAddr;
  addresses.DepinGbSettlement1155Impl = settleImplAddr;
  addresses.DeveloperTokenFxRegistry = registryAddr;
  addresses.TestDeveloperFxERC20 = tgb5;
  addresses.TGB5PayByUsePassTokenId = PASS_TOKEN_ID.toString();
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n");

  const out = {
    network: "conet",
    chainId: "224422",
    timestamp: new Date().toISOString(),
    tgb5,
    registry: registryAddr,
    settlement: settlementAddr,
    settlementImpl: settleImplAddr,
    gbToken: gbAddr,
    developer,
    passTokenId: PASS_TOKEN_ID.toString(),
    passKind: "PAY_BY_USE",
    expiresAt: EXPIRES_AT.toString(),
    gbPerFullToken: GB_PER_FULL_TOKEN.toString(),
    rate: "1 TGB5 = 5 GB",
    economics:
      "Settle usage U GB via NFT#: burn ceil_whole_tokens(U), mint 5N GB; miner gets U; developer gets 5N-U surplus",
    txs: {
      settlementUpgrade: upTx.hash,
      registerToken: txReg.hash,
      configurePass: txPass.hash,
      mintPass: txMint.hash,
    },
  };
  fs.writeFileSync(OUT_PATH, JSON.stringify(out, null, 2) + "\n");
  console.log("[6] wrote", OUT_PATH);

  console.log("=".repeat(60));
  console.log("DONE — TGB5 registered + NFT#%s PayByUse + surplus upgrade", PASS_TOKEN_ID.toString());
  console.log("=".repeat(60));
  console.log("Next verify:");
  console.log("  npx tsx scripts/verifyDepinGbSettlement1155ImplConet.ts  (if present)");
  console.log("  or Blockscout v2 standard-input for", settleImplAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
