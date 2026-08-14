/**
 * Deploy/upgrade developer FX stake gate + mint authority split + DeveloperFxIssuer.
 *
 * Deploys:
 *  - TreasuryDeveloperFxLib
 *  - DeveloperFxIssuer (linked lib)
 * Upgrades:
 *  - TreasuryCanonicalERC20V3 (TGB5) — stake + BURN_ROLE
 *  - TreasuryBridgeV3 — developerFxIssuer + mintDeveloperFxFromRegistry + forward gate
 *  - DeveloperTokenFxRegistry — issuer register + stake qualify + treasury mint path
 *  - DepinGbSettlement1155 — treasury/issuer FX register + miner gas refund
 *
 * Usage: npm run compile && npx tsx scripts/upgradeDeveloperFxStakeGateConet.ts
 *
 * Env:
 *   MINER_GAS_REFUND_WEI — default 0.01 CONET
 *   SKIP_VERIFY=1 — skip Blockscout verify
 */

import fs from "fs";
import path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import { spawnSync } from "child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RPC = process.env.CONET_RPC_URL?.trim() || "https://rpc1.conet.network";
const MASTER_PATH = path.join(homedir(), ".master.json");
const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const SETTLE_PATH = path.join(__dirname, "..", "deployments", "conet-DepinGbSettlement1155.json");
const REG_PATH = path.join(__dirname, "..", "deployments", "conet-DeveloperTokenFxRegistry.json");
const TGB5_PATH = path.join(__dirname, "..", "deployments", "conet-TestDeveloperFxERC20.json");
const OUT_PATH = path.join(__dirname, "..", "deployments", "conet-developer-fx-stake-gate.json");

const TREASURY = "0xa208982212978550594A7FEEB70a61665d129003";
const SETTLE_DEFAULT = "0x06cf5bF56DF3E327FB30214E001A67456aaBB287";
const REG_DEFAULT = "0x3B00a3F7341C0449e7a3D6e466f85F6F39dFf6e0";
const TGB5_DEFAULT = "0xEb8c8b0f4e3f779D8A8d863580AaaD72AFebe242";

const MIN_STAKE_WEI = 10n * 10n ** 18n;
const DEPLOY_FEE_USDC6 = 10n * 10n ** 6n;
const MINER_GAS_REFUND_WEI = BigInt(process.env.MINER_GAS_REFUND_WEI || "10000000000000000");

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

function loadArtifact(name: string): {
  abi: unknown[];
  bytecode: string;
  linkReferences?: Record<string, Record<string, { start: number; length: number }[]>>;
} {
  const p = path.join(__dirname, "..", "artifacts", "src", "b-unit", `${name}.sol`, `${name}.json`);
  if (!fs.existsSync(p)) throw new Error(`Missing ${p}; npm run compile`);
  const j = JSON.parse(fs.readFileSync(p, "utf-8"));
  return { abi: j.abi, bytecode: j.bytecode, linkReferences: j.linkReferences };
}

function linkBytecode(
  bytecode: string,
  linkReferences: Record<string, Record<string, { start: number; length: number }[]>> | undefined,
  libraries: Record<string, string>,
): string {
  if (!linkReferences || Object.keys(linkReferences).length === 0) return bytecode;
  let bc = bytecode.startsWith("0x") ? bytecode : `0x${bytecode}`;
  for (const file of Object.keys(linkReferences)) {
    for (const lib of Object.keys(linkReferences[file])) {
      const short = lib.includes(":") ? lib.split(":").pop()! : lib;
      const addr = (libraries[lib] || libraries[short] || "").replace(/^0x/i, "").toLowerCase();
      if (!addr || addr.length !== 40) throw new Error(`Missing library address for ${lib}`);
      for (const { start, length } of linkReferences[file][lib]) {
        if (length !== 20) throw new Error(`Unexpected link length ${length} for ${lib}`);
        const from = 2 + start * 2;
        bc = bc.slice(0, from) + addr + bc.slice(from + 40);
      }
    }
  }
  return bc;
}

async function deployContract(
  wallet: ethers.Wallet,
  name: string,
  libraries?: Record<string, string>,
  ctorArgs: unknown[] = [],
): Promise<string> {
  const art = loadArtifact(name);
  const bytecode = linkBytecode(art.bytecode, art.linkReferences, libraries || {});
  const Factory = new ethers.ContractFactory(art.abi as ethers.InterfaceAbi, bytecode, wallet);
  const c = await Factory.deploy(...ctorArgs);
  await c.waitForDeployment();
  return await c.getAddress();
}

function runVerify(label: string, args: string[], env: Record<string, string>) {
  console.log(`[verify] ${label}…`);
  const r = spawnSync("npx", ["tsx", ...args], {
    cwd: path.join(__dirname, ".."),
    env: { ...process.env, ...env },
    stdio: "inherit",
  });
  if (r.status !== 0) {
    console.warn(`[verify] ${label} exited ${r.status}`);
    return false;
  }
  return true;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  if ((await provider.getNetwork()).chainId !== 224422n) throw new Error("need CoNET 224422");
  const wallet = new ethers.Wallet(loadAdminPk(), provider);
  const addresses = loadJson(ADDRESSES_PATH);
  const settleJson = loadJson(SETTLE_PATH) as { proxy?: string; implementation?: string };
  const regJson = loadJson(REG_PATH) as { proxy?: string; implementation?: string };
  const tgb5Json = loadJson(TGB5_PATH) as { token?: string; tokenImpl?: string };

  const treasury = (addresses.TreasuryBridgeV3 as string) || TREASURY;
  const settlementAddr = (settleJson.proxy || addresses.DepinGbSettlement1155 || SETTLE_DEFAULT) as string;
  const registryAddr = (regJson.proxy || addresses.DeveloperTokenFxRegistry || REG_DEFAULT) as string;
  const tgb5 = (tgb5Json.token || addresses.TestDeveloperFxERC20 || TGB5_DEFAULT) as string;
  const conetUsdc = (addresses.conetUsdc as string) || "";

  console.log("=".repeat(60));
  console.log("Upgrade developer FX stake gate + Issuer + mint authority");
  console.log("=".repeat(60));
  console.log({
    treasury,
    settlementAddr,
    registryAddr,
    tgb5,
    conetUsdc,
    minStakeWei: MIN_STAKE_WEI.toString(),
    deployFeeUsdc6: DEPLOY_FEE_USDC6.toString(),
    minerGasRefundWei: MINER_GAS_REFUND_WEI.toString(),
    admin: wallet.address,
    balance: ethers.formatEther(await provider.getBalance(wallet.address)),
  });

  const BURN_ROLE = ethers.id("BURN_ROLE");
  const TREASURY_ROLE = ethers.id("TREASURY_ROLE");

  // ---- 1) TGB5 Canonical ----
  const tgb5Impl = await deployContract(wallet, "TreasuryCanonicalERC20V3");
  console.log("[1] TGB5 impl", tgb5Impl);
  const tgb5Proxy = new ethers.Contract(
    tgb5,
    [
      "function upgradeToAndCall(address,bytes)",
      "function hasRole(bytes32,address) view returns (bool)",
      "function bindDeveloperStakeTreasury(address)",
      "function developerCnetStake() view returns (uint256)",
      "function isTreasuryQualified() view returns (bool)",
      "function depositDeveloperStake() payable",
      "function setBurner(address)",
      "function revokeTreasury(address)",
      "function setTreasury(address)",
    ],
    wallet,
  );
  if (!(await tgb5Proxy.hasRole(ethers.ZeroHash, wallet.address))) {
    throw new Error("wallet is not TGB5 DEFAULT_ADMIN_ROLE");
  }
  const tgb5Up = await tgb5Proxy.upgradeToAndCall(tgb5Impl, "0x");
  await tgb5Up.wait();
  console.log("[1b] TGB5 upgrade", tgb5Up.hash);

  // ---- 2) Lib + DeveloperFxIssuer ----
  const fxLib = await deployContract(wallet, "TreasuryDeveloperFxLib");
  console.log("[2] TreasuryDeveloperFxLib", fxLib);
  const issuerAddr = await deployContract(wallet, "DeveloperFxIssuer", {
    TreasuryDeveloperFxLib: fxLib,
  }, [wallet.address]);
  console.log("[2b] DeveloperFxIssuer", issuerAddr);

  const issuer = new ethers.Contract(
    issuerAddr,
    [
      "function setWiring(address,address,address)",
      "function setDeployFeeAsset(address)",
      "function setEconomics(uint256,uint256,uint256)",
      "function setDeveloperFxToken(address,bool)",
      "function owner() view returns (address)",
      "function isForwardAllowed(address) view returns (bool)",
      "function developerTokenMinStakeWei() view returns (uint256)",
      "function registry() view returns (address)",
    ],
    wallet,
  );
  if ((await issuer.owner()).toLowerCase() !== wallet.address.toLowerCase()) {
    throw new Error("issuer owner mismatch");
  }

  // ---- 3) TreasuryBridgeV3 (no library link) ----
  const treasuryImpl = await deployContract(wallet, "TreasuryBridgeV3");
  console.log("[3] Treasury impl", treasuryImpl);
  const treasuryC = new ethers.Contract(
    treasury,
    [
      "function upgradeToAndCall(address,bytes)",
      "function owner() view returns (address)",
      "function setDeveloperFxIssuer(address)",
      "function developerFxIssuer() view returns (address)",
      "function isDeveloperFxForwardAllowed(address) view returns (bool)",
      "function feeSettlementAsset() view returns (address)",
      "function mintDeveloperFxFromRegistry(address,address,uint256)",
    ],
    wallet,
  );
  if ((await treasuryC.owner()).toLowerCase() !== wallet.address.toLowerCase()) {
    throw new Error(`treasury owner mismatch: ${await treasuryC.owner()}`);
  }
  const treUp = await treasuryC.upgradeToAndCall(treasuryImpl, "0x");
  await treUp.wait();
  console.log("[3b] Treasury upgrade", treUp.hash);

  const feeAsset = (await treasuryC.feeSettlementAsset()) || conetUsdc;
  if (!feeAsset || feeAsset === ethers.ZeroAddress) {
    throw new Error("feeSettlementAsset unset on treasury — setFeeSettlement first");
  }

  const setIssuerTx = await treasuryC.setDeveloperFxIssuer(issuerAddr);
  await setIssuerTx.wait();
  console.log("[3c] setDeveloperFxIssuer", setIssuerTx.hash);

  const wireTx = await issuer.setWiring(treasury, registryAddr, settlementAddr);
  await wireTx.wait();
  const feeTx = await issuer.setDeployFeeAsset(feeAsset);
  await feeTx.wait();
  const econTx = await issuer.setEconomics(MIN_STAKE_WEI, MINER_GAS_REFUND_WEI, DEPLOY_FEE_USDC6);
  await econTx.wait();
  console.log("[3d] Issuer wiring + economics", {
    feeAsset,
    minStake: (await issuer.developerTokenMinStakeWei()).toString(),
  });

  // ---- 4) Registry ----
  const regImpl = await deployContract(wallet, "DeveloperTokenFxRegistry");
  console.log("[4] Registry impl", regImpl);
  const registry = new ethers.Contract(
    registryAddr,
    [
      "function upgradeToAndCall(address,bytes)",
      "function admins(address) view returns (bool)",
      "function setTreasury(address)",
      "function setFxIssuer(address)",
      "function treasury() view returns (address)",
      "function fxIssuer() view returns (address)",
    ],
    wallet,
  );
  if (!(await registry.admins(wallet.address))) throw new Error("not registry admin");
  const regUp = await registry.upgradeToAndCall(regImpl, "0x");
  await regUp.wait();
  if ((await registry.treasury()).toLowerCase() !== treasury.toLowerCase()) {
    await (await registry.setTreasury(treasury)).wait();
  }
  await (await registry.setFxIssuer(issuerAddr)).wait();
  console.log("[4b] Registry upgrade + fxIssuer", regUp.hash);

  // ---- 5) Settlement ----
  const setImpl = await deployContract(wallet, "DepinGbSettlement1155");
  console.log("[5] Settlement impl", setImpl);
  const settlement = new ethers.Contract(
    settlementAddr,
    [
      "function upgradeToAndCall(address,bytes)",
      "function admins(address) view returns (bool)",
      "function setTreasury(address)",
      "function setFxIssuer(address)",
      "function setDeveloperTokenFxRegistry(address)",
      "function developerTokenFxRegistry() view returns (address)",
      "function treasury() view returns (address)",
    ],
    wallet,
  );
  if (!(await settlement.admins(wallet.address))) throw new Error("not settlement admin");
  const setUp = await settlement.upgradeToAndCall(setImpl, "0x");
  await setUp.wait();
  await (await settlement.setTreasury(treasury)).wait();
  await (await settlement.setFxIssuer(issuerAddr)).wait();
  if ((await settlement.developerTokenFxRegistry()).toLowerCase() !== registryAddr.toLowerCase()) {
    await (await settlement.setDeveloperTokenFxRegistry(registryAddr)).wait();
  }
  console.log("[5b] Settlement upgrade + treasury/issuer", setUp.hash);

  // ---- 6) TGB5 roles + stake (policy = Issuer) ----
  if (await tgb5Proxy.hasRole(TREASURY_ROLE, registryAddr)) {
    await (await tgb5Proxy.revokeTreasury(registryAddr)).wait();
    console.log("[6a] revoked legacy TREASURY_ROLE from registry");
  }
  // Also revoke deployer EOA mint if present
  if (await tgb5Proxy.hasRole(TREASURY_ROLE, wallet.address)) {
    await (await tgb5Proxy.revokeTreasury(wallet.address)).wait();
    console.log("[6a] revoked TREASURY_ROLE from admin EOA");
  }
  if (!(await tgb5Proxy.hasRole(TREASURY_ROLE, treasury))) {
    await (await tgb5Proxy.setTreasury(treasury)).wait();
    console.log("[6a] setTreasury(treasury)");
  }
  if (!(await tgb5Proxy.hasRole(BURN_ROLE, registryAddr))) {
    await (await tgb5Proxy.setBurner(registryAddr)).wait();
    console.log("[6a] setBurner(registry)");
  }

  await (await tgb5Proxy.bindDeveloperStakeTreasury(issuerAddr)).wait();
  console.log("[6b] bindDeveloperStakeTreasury(Issuer)");

  let stake = await tgb5Proxy.developerCnetStake();
  if (stake < MIN_STAKE_WEI) {
    const need = MIN_STAKE_WEI - stake;
    const bal = await provider.getBalance(wallet.address);
    if (bal < need + 10n ** 16n) {
      throw new Error(`need ${ethers.formatEther(need)} CONET stake; balance ${ethers.formatEther(bal)}`);
    }
    console.log(`[6c] depositing ${ethers.formatEther(need)} CONET stake…`);
    await (await tgb5Proxy.depositDeveloperStake({ value: need })).wait();
    stake = await tgb5Proxy.developerCnetStake();
  }
  const qualified = await tgb5Proxy.isTreasuryQualified();
  console.log("[6d] stake", stake.toString(), "qualified", qualified);
  if (!qualified) throw new Error("TGB5 still unqualified");

  await (await issuer.setDeveloperFxToken(tgb5, true)).wait();
  console.log("[6e] Issuer.setDeveloperFxToken(TGB5,true)");

  const forwardOk = await treasuryC.isDeveloperFxForwardAllowed(tgb5);
  const issuerOk = await issuer.isForwardAllowed(tgb5);
  console.log("[7] forwardAllowed treasury/issuer", forwardOk, issuerOk);
  if (!forwardOk || !issuerOk) throw new Error("forward still blocked");

  // Mint authority smoke: registry must NOT have TREASURY_ROLE; treasury must
  const regIsMinter = await tgb5Proxy.hasRole(TREASURY_ROLE, registryAddr);
  const treIsMinter = await tgb5Proxy.hasRole(TREASURY_ROLE, treasury);
  const regIsBurner = await tgb5Proxy.hasRole(BURN_ROLE, registryAddr);
  console.log("[7b] roles", { regIsMinter, treIsMinter, regIsBurner });
  if (regIsMinter) throw new Error("registry still has TREASURY_ROLE (mint)");
  if (!treIsMinter) throw new Error("treasury missing TREASURY_ROLE");
  if (!regIsBurner) throw new Error("registry missing BURN_ROLE");

  // ---- Persist ----
  settleJson.implementation = setImpl;
  settleJson.proxy = settlementAddr;
  settleJson.upgradedAt = new Date().toISOString();
  fs.writeFileSync(SETTLE_PATH, JSON.stringify(settleJson, null, 2) + "\n");

  regJson.implementation = regImpl;
  regJson.proxy = registryAddr;
  regJson.upgradedAt = new Date().toISOString();
  regJson.fxIssuer = issuerAddr;
  fs.writeFileSync(REG_PATH, JSON.stringify(regJson, null, 2) + "\n");

  tgb5Json.tokenImpl = tgb5Impl;
  tgb5Json.upgradedAt = new Date().toISOString();
  tgb5Json.developerStake = true;
  tgb5Json.stakePolicy = issuerAddr;
  fs.writeFileSync(TGB5_PATH, JSON.stringify(tgb5Json, null, 2) + "\n");

  addresses.DepinGbSettlement1155Impl = setImpl;
  addresses.DeveloperTokenFxRegistryImpl = regImpl;
  addresses.TestDeveloperFxERC20Impl = tgb5Impl;
  addresses.TreasuryBridgeV3Impl = treasuryImpl;
  addresses.DeveloperFxIssuer = issuerAddr;
  addresses.TreasuryDeveloperFxLib = fxLib;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n");

  const out = {
    network: "conet",
    chainId: "224422",
    timestamp: new Date().toISOString(),
    treasury,
    treasuryImpl,
    treasuryUpgradeTx: treUp.hash,
    developerFxIssuer: issuerAddr,
    treasuryDeveloperFxLib: fxLib,
    settlement: settlementAddr,
    settlementImpl: setImpl,
    settlementUpgradeTx: setUp.hash,
    registry: registryAddr,
    registryImpl: regImpl,
    registryUpgradeTx: regUp.hash,
    tgb5,
    tgb5Impl,
    tgb5UpgradeTx: tgb5Up.hash,
    feeAsset,
    economics: {
      minStakeWei: MIN_STAKE_WEI.toString(),
      minerGasRefundWei: MINER_GAS_REFUND_WEI.toString(),
      deployFeeUsdc6: DEPLOY_FEE_USDC6.toString(),
    },
    tgb5StakeWei: stake.toString(),
    mintAuthority: {
      treasuryHasTreasuryRole: treIsMinter,
      registryHasTreasuryRole: regIsMinter,
      registryHasBurnRole: regIsBurner,
      note: "Canonical mint only via treasury; Registry burn-only; GB→mint via treasury.mintDeveloperFxFromRegistry",
    },
  };
  fs.writeFileSync(OUT_PATH, JSON.stringify(out, null, 2) + "\n");
  console.log("[8] wrote", OUT_PATH);

  if (process.env.SKIP_VERIFY === "1") {
    console.log("SKIP_VERIFY=1 — done without Blockscout");
    return;
  }

  console.log("[9] Blockscout verify…");
  const okSettle = runVerify("Settlement", ["scripts/verifyDepinGbSettlement1155Conet.ts"], {
    IMPL: setImpl,
    SKIP_PROXY: "1",
  });
  const okTre = runVerify("Treasury", ["scripts/verifyTreasuryBridgeV3ImplConet.ts"], {
    TREASURY_IMPL: treasuryImpl,
  });
  const okCanon = runVerify("Canonical TGB5", ["scripts/verifyTreasuryCanonicalERC20V3Conet.ts"], {
    IMPL: tgb5Impl,
  });
  const okReg = runVerify("Registry", ["scripts/verifyDeveloperTokenFxRegistryConet.ts"], {
    IMPL: regImpl,
    SKIP_PROXY: "1",
  });
  const okIssuer = runVerify("Issuer", ["scripts/verifyDeveloperFxIssuerConet.ts"], {
    ISSUER: issuerAddr,
    FX_LIB: fxLib,
    OWNER: wallet.address,
  });

  if (!okSettle || !okTre || !okCanon || !okReg || !okIssuer) {
    console.warn("Some verifies failed — check logs / re-run verify scripts");
    process.exitCode = 2;
  } else {
    console.log("DONE — all verifies submitted/confirmed");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
