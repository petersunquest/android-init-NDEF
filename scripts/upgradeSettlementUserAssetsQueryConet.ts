/**
 * Upgrade DepinGbSettlement1155 with miner one-shot asset query + seed NFT#5 enumeration.
 *
 * Usage: npm run compile && npx tsx scripts/upgradeSettlementUserAssetsQueryConet.ts
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
const OUT_PATH = path.join(__dirname, "..", "deployments", "conet-settlement-user-assets-query.json");
const SETTLE_DEFAULT = "0x06cf5bF56DF3E327FB30214E001A67456aaBB287";
const PASS_TOKEN_ID = 5n;

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

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  if ((await provider.getNetwork()).chainId !== 224422n) throw new Error("need CoNET 224422");
  const wallet = new ethers.Wallet(loadAdminPk(), provider);
  const addresses = loadJson(ADDRESSES_PATH);
  const settleJson = loadJson(SETTLE_PATH) as { proxy?: string; implementation?: string };
  const settlementAddr = (settleJson.proxy || addresses.DepinGbSettlement1155 || SETTLE_DEFAULT) as string;

  const artPath = path.join(
    __dirname,
    "..",
    "artifacts",
    "src",
    "b-unit",
    "DepinGbSettlement1155.sol",
    "DepinGbSettlement1155.json",
  );
  if (!fs.existsSync(artPath)) throw new Error("compile first");
  const art = JSON.parse(fs.readFileSync(artPath, "utf-8"));
  const Factory = new ethers.ContractFactory(art.abi, art.bytecode, wallet);
  const impl = await Factory.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  console.log("[1] impl", implAddr);

  const settlement = new ethers.Contract(
    settlementAddr,
    [
      "function upgradeToAndCall(address,bytes)",
      "function admins(address) view returns (bool)",
      "function seedConfiguredPassIds(uint256[])",
      "function configuredPassCount() view returns (uint256)",
      "function configuredPassIds() view returns (uint256[])",
      "function getUserSettlementAssets(address) view returns (tuple(address user,uint256 gbTotal,uint256 gbFree,uint256 gbPaid,uint256 payerGbBurnedTotal,tuple(uint256 passTokenId,uint256 balance,address developer,uint64 expiresAt,uint8 kind,bool active,address fxErc20,uint256 userFxBalance,uint256 issuerFxBalance,uint256 gbPerFullToken,bool fxEnabled)[] passes))",
      "function suggestSettleRoute(address,uint256) view returns (uint256,uint8,uint8,address,bool)",
    ],
    wallet,
  );
  if (!(await settlement.admins(wallet.address))) throw new Error("not admin");

  const upTx = await settlement.upgradeToAndCall(implAddr, "0x");
  await upTx.wait();
  console.log("[2] upgrade", upTx.hash);

  const seedTx = await settlement.seedConfiguredPassIds([PASS_TOKEN_ID]);
  await seedTx.wait();
  console.log("[3] seedConfiguredPassIds #5", seedTx.hash);

  const count = await settlement.configuredPassCount();
  const ids = await settlement.configuredPassIds();
  console.log("[4] configuredPassCount", count.toString(), "ids", ids.map((x: bigint) => x.toString()));

  const snap = await settlement.getUserSettlementAssets(wallet.address);
  console.log("[5] getUserSettlementAssets(admin)", {
    gbTotal: snap.gbTotal.toString(),
    gbFree: snap.gbFree.toString(),
    gbPaid: snap.gbPaid.toString(),
    passes: snap.passes.length,
  });

  const route = await settlement.suggestSettleRoute(wallet.address, 1_000_000_000n);
  console.log("[6] suggestSettleRoute(1 GB)", {
    passTokenId: route[0].toString(),
    billingMode: Number(route[1]),
    kind: Number(route[2]),
    payer: route[3],
    feasible: route[4],
  });

  settleJson.implementation = implAddr;
  settleJson.proxy = settlementAddr;
  settleJson.upgradedAt = new Date().toISOString();
  settleJson.userAssetsQuery = { impl: implAddr, upgradeTx: upTx.hash, seedTx: seedTx.hash };
  fs.writeFileSync(SETTLE_PATH, JSON.stringify(settleJson, null, 2) + "\n");
  addresses.DepinGbSettlement1155Impl = implAddr;
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addresses, null, 2) + "\n");
  fs.writeFileSync(
    OUT_PATH,
    JSON.stringify(
      {
        network: "conet",
        chainId: "224422",
        timestamp: new Date().toISOString(),
        settlement: settlementAddr,
        impl: implAddr,
        upgradeTx: upTx.hash,
        seedTx: seedTx.hash,
        api: {
          getUserSettlementAssets: "getUserSettlementAssets(address)",
          getUserSettlementAssetsByIds: "getUserSettlementAssetsByIds(address,uint256[],bool)",
          suggestSettleRoute: "suggestSettleRoute(address,uint256)",
          configuredPassIds: "configuredPassIds()",
        },
      },
      null,
      2,
    ) + "\n",
  );

  console.log("[7] verify…");
  spawnSync("npx", ["tsx", "scripts/verifyDepinGbSettlement1155Conet.ts"], {
    cwd: path.join(__dirname, ".."),
    env: { ...process.env, IMPL: implAddr },
    stdio: "inherit",
  });
  console.log("DONE");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
