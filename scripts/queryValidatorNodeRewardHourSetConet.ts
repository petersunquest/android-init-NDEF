/**
 * 查询 ValidatorNodeRewardIndexer 的 NodeRewardHourSet 事件与 nodeHourlyReward 读数。
 *
 * 运行:
 *   npx tsx scripts/queryValidatorNodeRewardHourSetConet.ts
 *   npx tsx scripts/queryValidatorNodeRewardHourSetConet.ts --since-hours 48
 */

import * as fs from "fs";
import * as path from "path";
import { Contract, ethers, getAddress, id } from "ethers";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";
const BLOCKSCOUT = (process.env.CONET_BLOCKSCOUT_UI || "https://mainnet.conet.network").replace(/\/$/, "");

function loadIndexer(): string {
  const data = JSON.parse(fs.readFileSync(path.join(root, "deployments/conet-addresses.json"), "utf-8")) as {
    ValidatorNodeRewardIndexer?: string;
    validatorDepositRedeemDeployBlock?: number;
  };
  const raw = data.ValidatorNodeRewardIndexer?.trim();
  if (!raw || !ethers.isAddress(raw)) throw new Error("missing ValidatorNodeRewardIndexer");
  return getAddress(raw);
}

async function main() {
  const sinceHours = process.argv.includes("--since-hours")
    ? Number(process.argv[process.argv.indexOf("--since-hours") + 1] || 24)
    : 168;
  const indexerAddr = loadIndexer();
  const provider = new ethers.JsonRpcProvider(RPC, 224422);
  const latest = await provider.getBlockNumber();
  const fromBlock = Math.max(0, latest - Math.floor((sinceHours * 3600) / 12)); // ~12s blocks

  const topic = id("NodeRewardHourSet(address,address,uint256,uint256)");
  const logs = await provider.getLogs({
    address: indexerAddr,
    topics: [topic],
    fromBlock,
    toBlock: latest,
  });

  const iface = new ethers.Interface([
    "event NodeRewardHourSet(address indexed nodeWallet, address indexed beneficiary, uint256 indexed hourId, uint256 reward)",
  ]);

  console.log("Indexer:", indexerAddr);
  console.log("Explorer:", `${BLOCKSCOUT}/address/${indexerAddr}#events`);
  console.log(`Logs NodeRewardHourSet (last ~${sinceHours}h, blocks ${fromBlock}..${latest}):`, logs.length);
  console.log("");

  const c = new Contract(
    indexerAddr,
    ["function nodeHourlyReward(address nodeWallet, uint256 hourId) view returns (uint256)"],
    provider
  );

  for (const log of logs.slice(-10)) {
    const parsed = iface.parseLog({ topics: log.topics as string[], data: log.data });
    if (!parsed) continue;
    const nodeWallet = parsed.args.nodeWallet as string;
    const beneficiary = parsed.args.beneficiary as string;
    const hourId = parsed.args.hourId as bigint;
    const reward = parsed.args.reward as bigint;
    const onChain = await c.nodeHourlyReward(nodeWallet, hourId);
    console.log(
      `block ${log.blockNumber} tx ${log.transactionHash.slice(0, 14)}…`,
      `\n  node=${nodeWallet}`,
      `\n  beneficiary=${beneficiary}`,
      `\n  hourId=${hourId} reward=${ethers.formatEther(reward)} CNET`,
      `\n  nodeHourlyReward(on-chain)=${ethers.formatEther(onChain)} CNET`,
      ""
    );
  }

  if (!logs.length) {
    console.log("No NodeRewardHourSet yet. Hourly reporter must:");
    console.log("  1) parse validator_deposits.json pubkeys");
    console.log("  2) baseline at UTC hour start");
    console.log("  3) close hour after boundary + CONET_VALIDATOR_HOURLY_REWARD_REPORT_DELAY_SEC (default 120s)");
    console.log("Check validator logs: sudo journalctl -u conet-validator-redeem-listener -f | grep validatorRewardHourlyReporter");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
