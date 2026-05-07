/**
 * 升级 BeamioIndexerDiamond 的 ActionFacet：
 *   - `_recordTransaction` 中把 `subordinate` 去重后并入 `accountActionIds`，使
 *     `getAccountTransactionsPaged(POS_EOA)` 直接返回 POS 终端经手记录。
 *   - 新增 owner-only `backfillSubordinateIntoAccountIndex(uint256,uint256)` /
 *     `isSubordinateAccountIndexBackfilled(uint256)`，幂等地把历史 actionId 的
 *     subordinate 补到账户索引。
 *
 * 步骤:
 *   1. 部署新 ActionFacet
 *   2. 用 DiamondLoupe.facets() 查询当前 selector 归属，
 *      旧 ActionFacet 已存在的 selector → action=Replace；新 selector → action=Add
 *   3. 执行 diamondCut 单次切换全部 selector
 *   4. 按 500 条一批调用 backfillSubordinateIntoAccountIndex(0..txCount)
 *   5. 写回 deployments/conet-IndexerDiamond.json
 *
 * 用法:
 *   npx hardhat run scripts/upgradeActionFacetSubordinateAccountIndex.ts --network conet
 *
 * 可选 ENV:
 *   DIAMOND_ADDRESS=0x...        覆盖 deployments JSON 中的 diamond 字段
 *   SKIP_BACKFILL=1              只升级，不执行 backfill
 *   BACKFILL_BATCH=500           单次 backfill 范围（合约硬上限 500）
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

function getSelectors(abi: any): string[] {
  const arr = Array.isArray(abi) ? abi : abi?.abi || abi;
  if (!Array.isArray(arr)) throw new Error("Bad ABI");
  return [
    ...new Set(
      arr
        .filter((f: any) => f.type === "function")
        .map((f: any) =>
          ethersLib
            .id(`${f.name}(${(f.inputs || []).map((i: any) => i.type).join(",")})`)
            .slice(0, 10)
            .toLowerCase()
        )
    ),
  ].filter((s) => s !== DIAMOND_CUT_SELECTOR);
}

function getDiamondAddress(): string {
  const env = process.env.DIAMOND_ADDRESS;
  if (env) return env;
  const deployPath = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
  const deploy = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  if (!deploy.diamond) throw new Error("deployments/conet-IndexerDiamond.json 缺少 diamond 字段");
  return deploy.diamond as string;
}

async function main() {
  const { ethers } = await hreNetwork.connect();
  const [signer] = await ethers.getSigners();
  const diamond = getDiamondAddress();
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("升级 ActionFacet (subordinate → accountActionIds + backfill)");
  console.log("=".repeat(60));
  console.log("Network:", net.name, "ChainId:", net.chainId.toString());
  console.log("Signer:", signer.address);
  console.log("Diamond:", diamond);

  // 1. 部署新 ActionFacet
  console.log("\n[1/4] 部署新 ActionFacet...");
  const ActionFacet = await ethers.getContractFactory(FACET_NAME);
  const facet = await ActionFacet.deploy();
  await facet.waitForDeployment();
  const facetAddr = await facet.getAddress();
  console.log("  新 ActionFacet:", facetAddr);

  // 2. 选 selector：与链上现状对比
  const artifactPath = path.join(
    __dirname,
    "..",
    "artifacts",
    "src",
    "CoNETIndexTaskdiamond",
    "facets",
    `${FACET_NAME}.sol`,
    `${FACET_NAME}.json`
  );
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  const newSelectors = getSelectors(artifact.abi);

  const loupeAbi = [
    "function facets() external view returns (tuple(address facetAddress, bytes4[] functionSelectors)[])",
  ];
  const loupe = new ethersLib.Contract(diamond, loupeAbi, signer);
  const facetsList = (await loupe.facets()) as Array<[string, string[]]>;
  const existingSelectorOwner = new Map<string, string>();
  for (const f of facetsList) {
    const facetAddress = (f as any).facetAddress ?? f[0];
    const selectors: string[] = (f as any).functionSelectors ?? f[1];
    for (const sel of selectors) existingSelectorOwner.set(sel.toLowerCase(), facetAddress.toLowerCase());
  }

  const toAdd: string[] = [];
  const toReplace: string[] = [];
  for (const s of newSelectors) {
    if (existingSelectorOwner.has(s.toLowerCase())) toReplace.push(s);
    else toAdd.push(s);
  }
  console.log(`  newSelectors=${newSelectors.length} replace=${toReplace.length} add=${toAdd.length}`);
  if (toAdd.length > 0) {
    console.log("  新增 selectors:");
    for (const s of toAdd) console.log("   +", s);
  }

  if (toReplace.length === 0 && toAdd.length === 0) {
    console.log("⚠️ 没有需要升级的 selectors，终止");
    return;
  }

  const cuts: { facetAddress: string; action: number; functionSelectors: string[] }[] = [];
  if (toReplace.length) cuts.push({ facetAddress: facetAddr, action: 1, functionSelectors: toReplace });
  if (toAdd.length) cuts.push({ facetAddress: facetAddr, action: 0, functionSelectors: toAdd });

  // 3. 执行 diamondCut
  console.log("\n[2/4] 执行 diamondCut...");
  const diamondCutAbi = [
    "function diamondCut((address facetAddress,uint8 action,bytes4[] functionSelectors)[] _diamondCut,address _init,bytes _calldata) external",
  ];
  const diamondCut = new ethersLib.Contract(diamond, diamondCutAbi, signer);
  const tx = await diamondCut.diamondCut(cuts, ethersLib.ZeroAddress, "0x");
  console.log("  tx:", tx.hash);
  const rcpt = await tx.wait();
  console.log("  ✅ diamondCut 完成 (block", rcpt?.blockNumber?.toString(), ")");

  // 4. backfill 历史 subordinate → accountActionIds
  if (process.env.SKIP_BACKFILL === "1") {
    console.log("\n[3/4] SKIP_BACKFILL=1，跳过 backfill");
  } else {
    const batch = Math.min(500, Number(process.env.BACKFILL_BATCH || 500));
    const actionAbi = [
      "function getAccountActionCount(address account) view returns (uint256)",
      "function backfillSubordinateIntoAccountIndex(uint256 fromActionId, uint256 toActionId) external returns (uint256 pushed)",
      "function isSubordinateAccountIndexBackfilled(uint256 actionId) view returns (bool)",
    ];
    // txCount 没有直接 view，用 getLatestTransactionsPaged(0,1) 第一个返回值（uint256 total）
    const latestAbi = [
      "function getLatestTransactionsPaged(uint256 offset, uint256 limit) view returns (uint256 total, tuple(bytes32 id, bytes32 originalPaymentHash, uint256 chainId, bytes32 txCategory, string displayJson, uint64 timestamp, address payer, address payee, uint256 finalRequestAmountFiat6, uint256 finalRequestAmountUSDC6, bool isAAAccount, tuple(uint16 gasChainType, uint256 gasWei, uint256 gasUSDC6, uint256 serviceUSDC6, uint256 bServiceUSDC6, uint256 bServiceUnits6, address feePayer) fees, tuple(uint256 requestAmountFiat6, uint256 requestAmountUSDC6, uint8 currencyFiat, uint256 discountAmountFiat6, uint16 discountRateBps, uint256 taxAmountFiat6, uint16 taxRateBps, string afterNotePayer, string afterNotePayee) meta, bool exists, address topAdmin, address subordinate)[] page)",
    ];
    const latest = new ethersLib.Contract(diamond, latestAbi, signer);
    const totalRes = await latest.getLatestTransactionsPaged(0, 1);
    const total = Number(totalRes[0]);
    console.log(`\n[3/4] backfill: 全网 txCount=${total} batch=${batch}`);
    if (total === 0) {
      console.log("  txCount=0，无需 backfill");
    } else {
      const action = new ethersLib.Contract(diamond, actionAbi, signer);
      let from = 0;
      let totalPushed = 0n;
      while (from < total) {
        const to = Math.min(from + batch, total);
        process.stdout.write(`  backfill [${from}..${to})... `);
        const txBf = await action.backfillSubordinateIntoAccountIndex(from, to);
        const r = await txBf.wait();
        // 解析事件 SubordinateAccountIndexBackfilled(from, to, pushed)
        let pushed = 0n;
        const iface = new ethersLib.Interface([
          "event SubordinateAccountIndexBackfilled(uint256 fromActionId, uint256 toActionId, uint256 pushed)",
        ]);
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
        console.log(`pushed=${pushed.toString()} tx=${txBf.hash}`);
        from = to;
      }
      console.log(`  ✅ backfill 完成，累计追加 ${totalPushed.toString()} 条 subordinate→account 索引`);
    }
  }

  // 5. 更新部署文件
  console.log("\n[4/4] 写回部署文件");
  const deployPath = path.join(__dirname, "..", "deployments", "conet-IndexerDiamond.json");
  if (fs.existsSync(deployPath)) {
    const data = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
    data.facets = data.facets || {};
    const oldAddr = data.facets[FACET_NAME];
    data.facets[FACET_NAME] = facetAddr;
    data.lastSubordinateAccountIndexUpgradeAt = new Date().toISOString();
    data.lastSubordinateAccountIndexUpgradeFrom = oldAddr;
    data.lastSubordinateAccountIndexUpgradeTo = facetAddr;
    fs.writeFileSync(deployPath, JSON.stringify(data, null, 2));
    console.log("  已更新:", deployPath);
    console.log("  ActionFacet:", oldAddr, "→", facetAddr);
  }

  console.log("\n✅ 全部完成");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
