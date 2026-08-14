/**
 * Upgrade DepinGbSettlement1155: subscription NFT debits **issuer** FX ERC20 prepaid
 * (not customer GB). Re-affirm TGB5 NFT#5 as subscription series.
 *
 * Usage:
 *   npm run compile && npx tsx scripts/upgradeSettlementSubscriptionIssuerDebitConet.ts
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
const SETTLE_PATH = path.join(__dirname, "..", "deployments", "conet-DepinGbSettlement1155.json");
const TGB5_PASS_PATH = path.join(__dirname, "..", "deployments", "conet-TGB5-PayByUsePass.json");
const OUT_PATH = path.join(__dirname, "..", "deployments", "conet-settlement-subscription-issuer-debit.json");

const SETTLE_DEFAULT = "0x06cf5bF56DF3E327FB30214E001A67456aaBB287";
const TGB5_DEFAULT = "0xEb8c8b0f4e3f779D8A8d863580AaaD72AFebe242";
const REG_DEFAULT = "0x3B00a3F7341C0449e7a3D6e466f85F6F39dFf6e0";
const PASS_TOKEN_ID = 5n;
const PASS_KIND_SUBSCRIPTION = 2;
const EXPIRES_AT = 4102444800n; // ~2100

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

function loadArtifact(): { abi: unknown[]; bytecode: string } {
  const p = path.join(
    __dirname,
    "..",
    "artifacts",
    "src",
    "b-unit",
    "DepinGbSettlement1155.sol",
    "DepinGbSettlement1155.json",
  );
  if (!fs.existsSync(p)) throw new Error(`Missing ${p}; npm run compile`);
  const j = JSON.parse(fs.readFileSync(p, "utf-8"));
  return { abi: j.abi, bytecode: j.bytecode };
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  if ((await provider.getNetwork()).chainId !== 224422n) throw new Error("need CoNET 224422");

  const wallet = new ethers.Wallet(loadAdminPk(), provider);
  const addresses = loadJson(ADDRESSES_PATH);
  const settleJson = loadJson(SETTLE_PATH) as { proxy?: string; implementation?: string };
  const settlementAddr = (settleJson.proxy || addresses.DepinGbSettlement1155 || SETTLE_DEFAULT) as string;
  const tgb5 = (addresses.TestDeveloperFxERC20 || TGB5_DEFAULT) as string;
  const registry = (addresses.DeveloperTokenFxRegistry || REG_DEFAULT) as string;
  const developer = wallet.address;

  console.log("=".repeat(60));
  console.log("Upgrade Settlement: subscription → issuer ERC20 debit");
  console.log("=".repeat(60));
  console.log({ settlementAddr, tgb5, registry, developer, passTokenId: PASS_TOKEN_ID.toString() });

  const art = loadArtifact();
  const Factory = new ethers.ContractFactory(art.abi as ethers.InterfaceAbi, art.bytecode, wallet);
  const impl = await Factory.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  console.log("[1] impl", implAddr);

  const settlement = new ethers.Contract(
    settlementAddr,
    [
      "function upgradeToAndCall(address,bytes)",
      "function admins(address) view returns (bool)",
      "function configurePass(uint256,address,uint8,uint64,address)",
      "function passConfig(uint256) view returns (address,uint64,uint8,bool,address)",
      "function PASS_KIND_SUBSCRIPTION() view returns (uint8)",
      "function resolvePayer(address,uint256) view returns (address,uint8)",
    ],
    wallet,
  );
  if (!(await settlement.admins(wallet.address))) throw new Error("not settlement admin");

  const upTx = await settlement.upgradeToAndCall(implAddr, "0x");
  await upTx.wait();
  console.log("[2] upgrade", upTx.hash);

  const kind = Number(await settlement.PASS_KIND_SUBSCRIPTION());
  if (kind !== PASS_KIND_SUBSCRIPTION) throw new Error(`PASS_KIND_SUBSCRIPTION=${kind}`);

  const cfgTx = await settlement.configurePass(
    PASS_TOKEN_ID,
    developer,
    PASS_KIND_SUBSCRIPTION,
    EXPIRES_AT,
    tgb5,
  );
  await cfgTx.wait();
  console.log("[3] configurePass NFT#5 subscription", cfgTx.hash);

  const pc = await settlement.passConfig(PASS_TOKEN_ID);
  console.log("[4] passConfig", {
    developer: pc[0],
    expiresAt: pc[1].toString(),
    kind: Number(pc[2]),
    exists: pc[3],
    erc20: pc[4],
  });

  settleJson.implementation = implAddr;
  settleJson.proxy = settlementAddr;
  settleJson.upgradedAt = new Date().toISOString();
  settleJson.subscriptionIssuerDebit = {
    note: "Subscription NFT: burn issuer FX ERC20 prepaid; customer GB not charged",
    impl: implAddr,
    upgradeTx: upTx.hash,
    passTokenId: PASS_TOKEN_ID.toString(),
  };
  fs.writeFileSync(SETTLE_PATH, JSON.stringify(settleJson, null, 2) + "\n");

  addresses.DepinGbSettlement1155Impl = implAddr;
  addresses.TGB5PayByUsePassTokenId = PASS_TOKEN_ID.toString();
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n");

  const passOut = {
    ...loadJson(TGB5_PASS_PATH),
    timestamp: new Date().toISOString(),
    model: "subscription_issuer_erc20_debit",
    economics:
      "User holds NFT#5 → miner settle burns issuer TGB5 (FX) for usage GB → mint GB to miner; customer not charged. Issuer tops up via USDC→TGB5 (treasury payAndMint) or GB→TGB5 (burnGbMintDeveloper).",
    settlementImpl: implAddr,
    configurePassTx: cfgTx.hash,
    upgradeTx: upTx.hash,
  };
  fs.writeFileSync(TGB5_PASS_PATH, JSON.stringify(passOut, null, 2) + "\n");

  const out = {
    network: "conet",
    chainId: "224422",
    timestamp: new Date().toISOString(),
    settlement: settlementAddr,
    impl: implAddr,
    upgradeTx: upTx.hash,
    passTokenId: PASS_TOKEN_ID.toString(),
    tgb5,
    registry,
    developer,
  };
  fs.writeFileSync(OUT_PATH, JSON.stringify(out, null, 2) + "\n");
  console.log("[5] wrote", OUT_PATH);
  console.log("DONE");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
