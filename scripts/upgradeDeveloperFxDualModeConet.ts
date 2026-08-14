/**
 * Dual-mode developer FX: PayByUse (user burn + surplus → ERC20) / Subscription (issuer debit).
 * Upgrades Canonical TGB5 + DeveloperTokenFxRegistry + DepinGbSettlement1155; wires treasury gate;
 * binds TGB5 ↔ NFT#5 as FX_DUAL.
 *
 * Usage:
 *   npm run compile && npx tsx scripts/upgradeDeveloperFxDualModeConet.ts
 */

import fs from "fs";
import path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import { spawnSync } from "child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const RPC = process.env.CONET_RPC_URL?.trim() || "https://rpc1.conet.network";
const MASTER_PATH = path.join(homedir(), ".master.json");
const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const SETTLE_PATH = path.join(__dirname, "..", "deployments", "conet-DepinGbSettlement1155.json");
const REG_PATH = path.join(__dirname, "..", "deployments", "conet-DeveloperTokenFxRegistry.json");
const TGB5_PATH = path.join(__dirname, "..", "deployments", "conet-TestDeveloperFxERC20.json");
const TGB5_PASS_PATH = path.join(__dirname, "..", "deployments", "conet-TGB5-PayByUsePass.json");
const OUT_PATH = path.join(__dirname, "..", "deployments", "conet-developer-fx-dual-mode.json");

const SETTLE_DEFAULT = "0x06cf5bF56DF3E327FB30214E001A67456aaBB287";
const REG_DEFAULT = "0x3B00a3F7341C0449e7a3D6e466f85F6F39dFf6e0";
const TGB5_DEFAULT = "0xEb8c8b0f4e3f779D8A8d863580AaaD72AFebe242";
const TREASURY_DEFAULT = "0xa208982212978550594A7FEEB70a61665d129003";
const PASS_TOKEN_ID = 5n;
const PASS_KIND_FX_DUAL = 4;
const EXPIRES_AT = 4102444800n;
const MIN_GB_PER_FULL = 1_000_000_000n; // 1 GB baseline; TGB5 is 5 GB

function loadJson(p: string): Record<string, unknown> {
  if (!fs.existsSync(p)) return {};
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

function loadAdminPk(): string {
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const pk = (data?.settle_contractAdmin || [])[0];
  if (!pk) throw new Error("settle_contractAdmin[0] missing");
  return String(pk).startsWith("0x") ? pk : `0x${pk}`;
}

function loadArtifact(name: string): { abi: unknown[]; bytecode: string } {
  const p = path.join(__dirname, "..", "artifacts", "src", "b-unit", `${name}.sol`, `${name}.json`);
  if (!fs.existsSync(p)) throw new Error(`Missing ${p}; npm run compile`);
  const j = JSON.parse(fs.readFileSync(p, "utf-8"));
  return { abi: j.abi, bytecode: j.bytecode };
}

async function deployImpl(wallet: ethers.Wallet, name: string): Promise<string> {
  const art = loadArtifact(name);
  const Factory = new ethers.ContractFactory(art.abi as ethers.InterfaceAbi, art.bytecode, wallet);
  const impl = await Factory.deploy();
  await impl.waitForDeployment();
  return await impl.getAddress();
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  if ((await provider.getNetwork()).chainId !== 224422n) throw new Error("need CoNET 224422");

  const wallet = new ethers.Wallet(loadAdminPk(), provider);
  const addresses = loadJson(ADDRESSES_PATH);
  const settleJson = loadJson(SETTLE_PATH) as { proxy?: string; implementation?: string };
  const regJson = loadJson(REG_PATH) as { proxy?: string; implementation?: string };
  const tgb5Json = loadJson(TGB5_PATH) as { token?: string; tokenImpl?: string; treasury?: string };

  const settlementAddr = (settleJson.proxy || addresses.DepinGbSettlement1155 || SETTLE_DEFAULT) as string;
  const registryAddr = (regJson.proxy || addresses.DeveloperTokenFxRegistry || REG_DEFAULT) as string;
  const tgb5 = (tgb5Json.token || addresses.TestDeveloperFxERC20 || TGB5_DEFAULT) as string;
  const treasury = (tgb5Json.treasury || addresses.TreasuryBridgeV3 || TREASURY_DEFAULT) as string;

  console.log("=".repeat(60));
  console.log("Upgrade developer FX dual-mode (PayByUse + Subscription)");
  console.log("=".repeat(60));
  console.log({ settlementAddr, registryAddr, tgb5, treasury, developer: wallet.address });

  // ---- 1) Canonical TGB5 (rescueERC20) ----
  const tgb5Impl = await deployImpl(wallet, "TreasuryCanonicalERC20V3");
  console.log("[1] TGB5 Canonical impl", tgb5Impl);
  const tgb5Proxy = new ethers.Contract(
    tgb5,
    ["function upgradeToAndCall(address,bytes)", "function hasRole(bytes32,address) view returns (bool)"],
    wallet,
  );
  // AccessControl DEFAULT_ADMIN_ROLE == bytes32(0)
  if (!(await tgb5Proxy.hasRole(ethers.ZeroHash, wallet.address))) {
    throw new Error("wallet is not TGB5 DEFAULT_ADMIN_ROLE");
  }
  const tgb5Up = await tgb5Proxy.upgradeToAndCall(tgb5Impl, "0x");
  await tgb5Up.wait();
  console.log("[1b] TGB5 upgrade", tgb5Up.hash);

  // ---- 2) Registry ----
  const regImpl = await deployImpl(wallet, "DeveloperTokenFxRegistry");
  console.log("[2] Registry impl", regImpl);
  const registry = new ethers.Contract(
    registryAddr,
    [
      "function upgradeToAndCall(address,bytes)",
      "function admins(address) view returns (bool)",
      "function setTreasury(address)",
      "function setMinGbPerFullToken(uint256)",
      "function bindExistingTokenPass(address,uint256)",
      "function treasury() view returns (address)",
      "function minGbPerFullToken() view returns (uint256)",
      "function tokenToPassId(address) view returns (uint256)",
      "function tokens(address) view returns (bool,bool,uint8,uint256,address)",
    ],
    wallet,
  );
  if (!(await registry.admins(wallet.address))) throw new Error("not registry admin");
  const regUp = await registry.upgradeToAndCall(regImpl, "0x");
  await regUp.wait();
  console.log("[2b] Registry upgrade", regUp.hash);

  const txT = await registry.setTreasury(treasury);
  await txT.wait();
  const txMin = await registry.setMinGbPerFullToken(MIN_GB_PER_FULL);
  await txMin.wait();
  console.log("[2c] treasury + minGbPerFullToken set");

  // Ensure TGB5 still registered with rate > baseline
  const tok = await registry.tokens(tgb5);
  if (!tok[0]) throw new Error("TGB5 not registered on FX registry");
  if (tok[3] <= MIN_GB_PER_FULL) throw new Error(`TGB5 rate ${tok[3]} must be > ${MIN_GB_PER_FULL}`);

  const bindTx = await registry.bindExistingTokenPass(tgb5, PASS_TOKEN_ID);
  await bindTx.wait();
  console.log("[2d] bindExistingTokenPass TGB5↔#5", bindTx.hash);

  // ---- 3) Settlement ----
  const setImpl = await deployImpl(wallet, "DepinGbSettlement1155");
  console.log("[3] Settlement impl", setImpl);
  const settlement = new ethers.Contract(
    settlementAddr,
    [
      "function upgradeToAndCall(address,bytes)",
      "function admins(address) view returns (bool)",
      "function configurePass(uint256,address,uint8,uint64,address)",
      "function setDeveloperTokenFxRegistry(address)",
      "function developerTokenFxRegistry() view returns (address)",
      "function passConfig(uint256) view returns (address,uint64,uint8,bool,address)",
      "function erc20ToPassId(address) view returns (uint256)",
      "function PASS_KIND_PAY_BY_USE() view returns (uint8)",
      "function PASS_KIND_SUBSCRIPTION() view returns (uint8)",
      "function PASS_KIND_FX_DUAL() view returns (uint8)",
    ],
    wallet,
  );
  if (!(await settlement.admins(wallet.address))) throw new Error("not settlement admin");
  const setUp = await settlement.upgradeToAndCall(setImpl, "0x");
  await setUp.wait();
  console.log("[3b] Settlement upgrade", setUp.hash);

  const dual = Number(await settlement.PASS_KIND_FX_DUAL());
  if (dual !== PASS_KIND_FX_DUAL) throw new Error(`PASS_KIND_FX_DUAL=${dual}`);
  const sub = Number(await settlement.PASS_KIND_SUBSCRIPTION());
  if (sub !== 3) throw new Error(`PASS_KIND_SUBSCRIPTION expected 3, got ${sub}`);

  const regOnSettle = await settlement.developerTokenFxRegistry();
  if (regOnSettle.toLowerCase() !== registryAddr.toLowerCase()) {
    const txWire = await settlement.setDeveloperTokenFxRegistry(registryAddr);
    await txWire.wait();
    console.log("[3c] wired registry on settlement");
  }

  const cfgTx = await settlement.configurePass(
    PASS_TOKEN_ID,
    wallet.address,
    PASS_KIND_FX_DUAL,
    EXPIRES_AT,
    tgb5,
  );
  await cfgTx.wait();
  console.log("[3d] configurePass NFT#5 FX_DUAL", cfgTx.hash);

  const pc = await settlement.passConfig(PASS_TOKEN_ID);
  const linked = await settlement.erc20ToPassId(tgb5);
  const bound = await registry.tokenToPassId(tgb5);
  console.log("[4] verify", {
    developer: pc[0],
    kind: Number(pc[2]),
    erc20: pc[4],
    erc20ToPassId: linked.toString(),
    registryTokenToPassId: bound.toString(),
    treasury: await registry.treasury(),
    minGb: (await registry.minGbPerFullToken()).toString(),
  });
  if (linked !== PASS_TOKEN_ID || bound !== PASS_TOKEN_ID) throw new Error("1:1 link mismatch");
  if (Number(pc[2]) !== PASS_KIND_FX_DUAL) throw new Error("pass kind not FX_DUAL");

  // ---- Persist ----
  settleJson.implementation = setImpl;
  settleJson.proxy = settlementAddr;
  settleJson.upgradedAt = new Date().toISOString();
  settleJson.dualMode = {
    note: "PayByUse burns user FX (surplus→ERC20); Subscription burns issuer; NFT# FX_DUAL billingMode",
    impl: setImpl,
    upgradeTx: setUp.hash,
    passTokenId: PASS_TOKEN_ID.toString(),
    passKind: "FX_DUAL",
  };
  fs.writeFileSync(SETTLE_PATH, JSON.stringify(settleJson, null, 2) + "\n");

  regJson.implementation = regImpl;
  regJson.proxy = registryAddr;
  regJson.treasury = treasury;
  regJson.minGbPerFullToken = MIN_GB_PER_FULL.toString();
  regJson.upgradedAt = new Date().toISOString();
  fs.writeFileSync(REG_PATH, JSON.stringify(regJson, null, 2) + "\n");

  tgb5Json.tokenImpl = tgb5Impl;
  tgb5Json.upgradedAt = new Date().toISOString();
  tgb5Json.rescueERC20 = true;
  fs.writeFileSync(TGB5_PATH, JSON.stringify(tgb5Json, null, 2) + "\n");

  addresses.DepinGbSettlement1155Impl = setImpl;
  addresses.DeveloperTokenFxRegistryImpl = regImpl;
  addresses.TestDeveloperFxERC20Impl = tgb5Impl;
  addresses.TGB5PayByUsePassTokenId = PASS_TOKEN_ID.toString();
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n");

  const passOut = {
    ...loadJson(TGB5_PASS_PATH),
    timestamp: new Date().toISOString(),
    model: "fx_dual_paybyuse_and_subscription",
    passKind: "FX_DUAL",
    economics:
      "NFT#5 Dual: billingMode=2 PayByUse burns user TGB5 (whole tokens), miner gets usage GB, surplus GB → TGB5 contract (owner rescueERC20). billingMode=3 Subscription burns issuer TGB5 prepaid. Supply only via USDC→treasury mint.",
    settlementImpl: setImpl,
    registryImpl: regImpl,
    tgb5Impl,
    configurePassTx: cfgTx.hash,
    upgradeTx: setUp.hash,
  };
  fs.writeFileSync(TGB5_PASS_PATH, JSON.stringify(passOut, null, 2) + "\n");

  const out = {
    network: "conet",
    chainId: "224422",
    timestamp: new Date().toISOString(),
    settlement: settlementAddr,
    settlementImpl: setImpl,
    settlementUpgradeTx: setUp.hash,
    registry: registryAddr,
    registryImpl: regImpl,
    registryUpgradeTx: regUp.hash,
    tgb5,
    tgb5Impl,
    tgb5UpgradeTx: tgb5Up.hash,
    treasury,
    passTokenId: PASS_TOKEN_ID.toString(),
    passKind: PASS_KIND_FX_DUAL,
    bindTx: bindTx.hash,
    configurePassTx: cfgTx.hash,
  };
  fs.writeFileSync(OUT_PATH, JSON.stringify(out, null, 2) + "\n");
  console.log("[5] wrote", OUT_PATH);

  // Verify Settlement impl on Blockscout (best-effort)
  console.log("[6] verify Settlement impl…");
  const verify = spawnSync("npx", ["tsx", "scripts/verifyDepinGbSettlement1155Conet.ts"], {
    cwd: path.join(__dirname, ".."),
    env: { ...process.env, IMPL: setImpl, SKIP_PROXY: "1" },
    stdio: "inherit",
  });
  if (verify.status !== 0) {
    console.warn("Settlement verify exited", verify.status, "— re-run verifyDepinGbSettlement1155Conet.ts");
  }

  console.log("DONE");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
