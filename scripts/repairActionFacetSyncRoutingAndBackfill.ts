/**
 * 修复 BeamioIndexerDiamond 上 `syncTokenAction(...)` 仍指向旧 ActionFacet 的回归。
 *
 * 背景：
 *   2026-04-22 的 ActionFacet 升级（`upgradeActionFacetSubordinateAccountIndex.ts`）只把
 *   读路径 selector 切到了新 facet `0x3a0e389B…`，写路径 `syncTokenAction(0xd47349f7)`
 *   仍归属旧 facet `0x1FFC81D9…`。结果：
 *     - 升级时 backfill 把 actionId 0..2 推进 `accountActionIds[POS_EOA]`；
 *     - 升级后所有新交易都走旧 facet 的 `_recordTransaction`，从未把 `subordinate`
 *       并入 `accountActionIds`，导致 `getAccountActionCount(POS_EOA)` 卡在 3。
 *   现象：iOS POS `/Transactions` 永远只看到 3 条。
 *
 * 本脚本（与 `beamio-usercard-contract-change-workflow.mdc` 对齐：合约改动必须配套迁移脚本）：
 *   1. 部署最新源码的 `ActionFacet`（含 lines 220-225 的 `subordinate → accountActionIds` push）；
 *   2. 用 ContractFactory.interface.fragments 计算新 facet 的全部 function selectors，
 *      硬断言其中包含 `syncTokenAction(0xd47349f7)`；
 *   3. 通过 DiamondLoupe 比对当前归属，构造 Add+Replace cut；
 *   4. 执行 `diamondCut`，**post-cut 硬断言** `0xd47349f7` 已归属新 facet（避免再次半残）；
 *   5. 调用 `getTransactionCount()` 拿 txCount，按 500/批次循环
 *      `backfillSubordinateIntoAccountIndex(from, to)`，幂等地把全部历史 subordinate
 *      并入账户索引（已 backfill 过的 actionId 由合约 `done[id]` 标记自动跳过）；
 *   6. 写回 `deployments/conet-IndexerDiamond.json` 的 `facets.ActionFacet`，
 *      并记录 `lastSubordinateAccountIndexUpgradeAt/From/To`。
 *
 * 用法:
 *   npm run repair:indexer-action-sync:conet
 *
 * 可选 ENV：
 *   DIAMOND_ADDRESS=0x...          覆盖部署 JSON 中的 diamond
 *   SKIP_BACKFILL=1                只迁移 selector，不 backfill
 *   BACKFILL_BATCH=500             单次 backfill 范围（合约硬上限 500）
 *   ASSERT_POS_EOA=0x...           可选；若给出，会在前后打印
 *                                  `getAccountActionCount(POS_EOA)` 作健康检查
 */

import { network as hreNetwork } from "hardhat";
import { ethers as ethersLib } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DIAMOND_CUT_SELECTOR = "0x1f931c1c";
const FACET_NAME = "ActionFacet";
/** 写路径核心 selector：必须由含 `subordinate → accountActionIds` push 的新 facet 拥有 */
const SYNC_TOKEN_ACTION_SELECTOR = "0xd47349f7";

function getDiamondAddress(): string {
  const env = process.env.DIAMOND_ADDRESS;
  if (env) return env;
  const deployPath = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
  if (!fs.existsSync(deployPath)) {
    throw new Error("未找到 deployments/conet-IndexerDiamond.json，请通过 DIAMOND_ADDRESS env 指定");
  }
  const deploy = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  if (!deploy.diamond) throw new Error("deployments/conet-IndexerDiamond.json 缺少 diamond 字段");
  return deploy.diamond as string;
}

async function main() {
  const { ethers } = (await hreNetwork.connect()) as any;
  const [signer] = await ethers.getSigners();
  const diamond = getDiamondAddress();
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(70));
  console.log("修复 ActionFacet syncTokenAction 路由 + 历史 subordinate backfill");
  console.log("=".repeat(70));
  console.log("Network:", net.name, "ChainId:", net.chainId.toString());
  console.log("Signer :", signer.address);
  console.log("Diamond:", diamond);

  // 0. 健康检查：打印当前 syncTokenAction owner + 可选 POS_EOA 的索引计数
  const loupeAbi = [
    "function facets() view returns (tuple(address facetAddress, bytes4[] functionSelectors)[])",
    "function facetAddress(bytes4 _functionSelector) view returns (address)",
  ];
  const loupe = new ethersLib.Contract(diamond, loupeAbi, signer);
  const ownerBefore = (await loupe.facetAddress(SYNC_TOKEN_ACTION_SELECTOR)).toLowerCase();
  console.log(`\n[0/5] 当前 syncTokenAction(${SYNC_TOKEN_ACTION_SELECTOR}) owner = ${ownerBefore}`);

  const accountAbi = [
    "function getAccountActionCount(address account) view returns (uint256)",
    "function getTransactionCount() view returns (uint256)",
    "function backfillSubordinateIntoAccountIndex(uint256 fromActionId, uint256 toActionId) returns (uint256 pushed)",
    "function isSubordinateAccountIndexBackfilled(uint256 actionId) view returns (bool)",
    "event SubordinateAccountIndexBackfilled(uint256 fromActionId, uint256 toActionId, uint256 pushed)",
  ];
  const account = new ethersLib.Contract(diamond, accountAbi, signer);

  const posEoa = process.env.ASSERT_POS_EOA?.trim();
  let posCountBefore: bigint | null = null;
  if (posEoa && ethersLib.isAddress(posEoa)) {
    posCountBefore = (await account.getAccountActionCount(posEoa)) as bigint;
    console.log(`     POS_EOA ${posEoa} getAccountActionCount(before) = ${posCountBefore.toString()}`);
  }

  // 1. 部署最新源码的 ActionFacet
  console.log("\n[1/5] 部署新 ActionFacet …");
  const ActionFacet = await ethers.getContractFactory(FACET_NAME);
  const facet = await ActionFacet.deploy();
  await facet.waitForDeployment();
  const newFacet = (await facet.getAddress()).toLowerCase();
  console.log("      新 ActionFacet:", newFacet);

  // 2. 计算新 facet selectors，硬断言包含 syncTokenAction
  const allSelectors: string[] = [
    ...new Set(
      (ActionFacet.interface.fragments as any[])
        .filter((f: any) => f.type === "function")
        .map((f: any) => (f.selector as string).toLowerCase())
    ),
  ].filter((s) => s !== DIAMOND_CUT_SELECTOR);
  console.log(`      新 facet 共 ${allSelectors.length} 个 selector`);
  if (!allSelectors.includes(SYNC_TOKEN_ACTION_SELECTOR)) {
    throw new Error(
      `新 ActionFacet 不包含 syncTokenAction(${SYNC_TOKEN_ACTION_SELECTOR})。` +
        " 请先 npm run compile 重新生成 artifacts，再次运行本脚本。"
    );
  }

  // 3. Loupe 比对，构造 Add/Replace cut
  console.log("\n[2/5] DiamondLoupe 比对当前 selector 归属 …");
  const toAdd: string[] = [];
  const toReplace: string[] = [];
  const stillOnOldByOwner = new Map<string, string[]>();
  for (const sel of allSelectors) {
    const owner = (await loupe.facetAddress(sel)).toLowerCase();
    if (owner === ethersLib.ZeroAddress.toLowerCase()) {
      toAdd.push(sel);
    } else if (owner === newFacet) {
      // 已经指向同地址 — 不可能（刚部署），跳过
      continue;
    } else {
      toReplace.push(sel);
      const list = stillOnOldByOwner.get(owner) ?? [];
      list.push(sel);
      stillOnOldByOwner.set(owner, list);
    }
  }
  console.log(`      toAdd=${toAdd.length} toReplace=${toReplace.length}`);
  for (const [owner, sels] of stillOnOldByOwner.entries()) {
    console.log(`      旧 owner ${owner} 持有 ${sels.length} 个 selector，将被 Replace 走`);
  }
  if (!toAdd.length && !toReplace.length) {
    console.log("      没有可迁移的 selector，终止");
    return;
  }

  // 4. 执行 diamondCut
  console.log("\n[3/5] 执行 diamondCut …");
  const diamondCutAbi = [
    "function diamondCut((address facetAddress,uint8 action,bytes4[] functionSelectors)[] _diamondCut,address _init,bytes _calldata) external",
  ];
  const diamondCut = new ethersLib.Contract(diamond, diamondCutAbi, signer);
  const cuts: { facetAddress: string; action: number; functionSelectors: string[] }[] = [];
  if (toReplace.length) cuts.push({ facetAddress: newFacet, action: 1, functionSelectors: toReplace });
  if (toAdd.length) cuts.push({ facetAddress: newFacet, action: 0, functionSelectors: toAdd });
  const cutTx = await diamondCut.diamondCut(cuts, ethersLib.ZeroAddress, "0x");
  console.log("      cut tx:", cutTx.hash);
  const cutRcpt = await cutTx.wait();
  console.log("      ✅ diamondCut 完成 (block", cutRcpt?.blockNumber?.toString(), ")");

  // 5. POST-CUT 硬断言：syncTokenAction 必须归属新 facet
  const ownerAfter = (await loupe.facetAddress(SYNC_TOKEN_ACTION_SELECTOR)).toLowerCase();
  if (ownerAfter !== newFacet) {
    throw new Error(
      `post-cut 校验失败：syncTokenAction(${SYNC_TOKEN_ACTION_SELECTOR}) owner=${ownerAfter}，` +
        `期望 ${newFacet}。链上仍可能写入未升级 facet —— 请人工排查。`
    );
  }
  console.log(`      ✅ syncTokenAction(${SYNC_TOKEN_ACTION_SELECTOR}) 已指向新 facet ${newFacet}`);

  // 6. backfill 历史 subordinate → accountActionIds
  if (process.env.SKIP_BACKFILL === "1") {
    console.log("\n[4/5] SKIP_BACKFILL=1，跳过 backfill");
  } else {
    const total = Number(await account.getTransactionCount());
    const batch = Math.min(500, Number(process.env.BACKFILL_BATCH || 500));
    console.log(`\n[4/5] backfill 历史 subordinate → accountActionIds: txCount=${total} batch=${batch}`);
    if (total === 0) {
      console.log("      txCount=0，无需 backfill");
    } else {
      const iface = new ethersLib.Interface([
        "event SubordinateAccountIndexBackfilled(uint256 fromActionId, uint256 toActionId, uint256 pushed)",
      ]);
      let from = 0;
      let totalPushed = 0n;
      while (from < total) {
        const to = Math.min(from + batch, total);
        process.stdout.write(`      backfill [${from}..${to}) … `);
        const tx = await account.backfillSubordinateIntoAccountIndex(from, to);
        const r = await tx.wait();
        let pushed = 0n;
        for (const log of r?.logs ?? []) {
          try {
            const parsed = iface.parseLog(log as any);
            if (parsed?.name === "SubordinateAccountIndexBackfilled") {
              pushed = BigInt(parsed.args.pushed.toString());
              break;
            }
          } catch {
            // ignore non-matching logs
          }
        }
        totalPushed += pushed;
        console.log(`pushed=${pushed.toString()} tx=${tx.hash}`);
        from = to;
      }
      console.log(`      ✅ backfill 完成，本次累计追加 ${totalPushed.toString()} 条索引`);
    }
  }

  // 7. 健康检查（可选）
  if (posEoa && posCountBefore != null) {
    const after = (await account.getAccountActionCount(posEoa)) as bigint;
    console.log(
      `\n[5/5] POS_EOA ${posEoa} getAccountActionCount: ${posCountBefore.toString()} → ${after.toString()}`
    );
  } else {
    console.log("\n[5/5] 跳过 POS_EOA 健康检查（未设置 ASSERT_POS_EOA）");
  }

  // 8. 写回部署文件
  const deployPath = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
  if (fs.existsSync(deployPath)) {
    const data = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
    data.facets = data.facets || {};
    const oldAddr = data.facets[FACET_NAME];
    data.facets[FACET_NAME] = newFacet;
    data.lastSubordinateAccountIndexUpgradeAt = new Date().toISOString();
    data.lastSubordinateAccountIndexUpgradeFrom = oldAddr;
    data.lastSubordinateAccountIndexUpgradeTo = newFacet;
    fs.writeFileSync(deployPath, JSON.stringify(data, null, 2));
    console.log("\n更新部署文件:", deployPath);
    console.log(`  ActionFacet: ${oldAddr} → ${newFacet}`);
  }

  console.log("\n✅ 全部完成");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
