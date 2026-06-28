/**
 * 一次性链上 smoke：向 RewardIndexer 写入 1 wei 并验收 NodeRewardHourSet 事件。
 * 仅用于部署验收；须 Settle 池钱包为 indexer admin。
 *
 * 运行（validator 主机，~/.master.json 已配置）:
 *   cd /home/peter/x402sdk && node ../BeamioContract/scripts/smokeValidatorNodeRewardHourSetConet.mjs
 *
 * 或本地（有 master.json + CoNET RPC）:
 *   node scripts/smokeValidatorNodeRewardHourSetConet.mjs
 */

import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Contract, ethers, getAddress, id } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const require = createRequire(import.meta.url);

const RPC = process.env.CONET_RPC_URL || "https://publicrpc.conet.network";

function loadAddresses() {
  const data = require(path.join(root, "deployments/conet-addresses.json"));
  return {
    redeem: getAddress(data.ValidatorDepositRedeem),
    indexer: getAddress(data.ValidatorNodeRewardIndexer),
  };
}

async function resolveNodeWallet(redeem, nodeIp) {
  const c = new Contract(
    redeem,
    [
      "function getWalletDepinNodeIps(address wallet) view returns (string[])",
      "function getDepinBeneficiaryByIp(string ip) view returns (address)",
      "function getNodeByValidatorPubkeyHash(bytes32) view returns (address)",
    ],
    new ethers.JsonRpcProvider(RPC, 224422)
  );
  // Prefer node registered under this validator IP
  try {
    const ips = await c.getWalletDepinNodeIps(redeem);
    void ips;
  } catch {
    /* optional */
  }
  const beneficiary = getAddress(await c.getDepinBeneficiaryByIp(nodeIp));
  if (beneficiary === ethers.ZeroAddress) throw new Error(`no beneficiary for nodeIp ${nodeIp}`);
  // Walk deposit pubkeys on host is heavy; use beneficiary's first registered node via getBeneficiaryNodeBundle if available
  const c2 = new Contract(
    redeem,
    ["function getBeneficiaryNodeBundle(address beneficiary) view returns (address[] nodeWallets, bytes[] pubkeys, string[] depinNodeIps, uint256[] guardianNodeIds, bool[] activeFlags)"],
    new ethers.JsonRpcProvider(RPC, 224422)
  );
  const bundle = await c2.getBeneficiaryNodeBundle(beneficiary);
  const wallets = bundle[0] ?? bundle.nodeWallets;
  const flags = bundle[4] ?? bundle.activeFlags;
  for (let i = 0; i < wallets.length; i++) {
    if (flags[i]) return getAddress(wallets[i]);
  }
  if (wallets?.length) return getAddress(wallets[0]);
  throw new Error(`no node wallet for beneficiary ${beneficiary}`);
}

async function main() {
  const nodeIp = process.env.CONET_VALIDATOR_NODE_IP?.trim() || "38.102.85.33";
  const { redeem, indexer } = loadAddresses();
  const provider = new ethers.JsonRpcProvider(RPC, 224422);
  const nodeWallet = await resolveNodeWallet(redeem, nodeIp);

  const hourId = process.env.SMOKE_HOUR_ID
    ? Number(process.env.SMOKE_HOUR_ID)
    : Math.floor(Date.now() / 1000 / 3600) - 1;

  const sdkRoot = process.env.X402SDK_ROOT?.trim() || path.join(root, "src/x402sdk");
  const mod = await import(path.join(sdkRoot, "dist/endpoint/validatorDepositRedeem.js"));
  const res = await mod.validatorRewardReportHourly([
    { nodeWallet, hourId, hourlyReward: 1n },
  ]);
  if (!res.ok) throw new Error(res.error);
  console.log("reportNodeRewardHourly ok:", res.txHash, "node=", nodeWallet, "hourId=", hourId);

  await new Promise((r) => setTimeout(r, 4000));
  const topic = id("NodeRewardHourSet(address,address,uint256,uint256)");
  const receipt = await provider.getTransactionReceipt(res.txHash);
  const logs = (receipt?.logs ?? []).filter(
    (l) => l.address.toLowerCase() === indexer.toLowerCase() && l.topics[0] === topic
  );
  console.log("NodeRewardHourSet logs in receipt:", logs.length);
  if (!logs.length) throw new Error("expected NodeRewardHourSet in receipt");

  const c = new Contract(indexer, ["function nodeHourlyReward(address,uint256) view returns (uint256)"], provider);
  const onChain = await c.nodeHourlyReward(nodeWallet, hourId);
  console.log("nodeHourlyReward(on-chain wei):", onChain.toString());
  if (onChain !== 1n) throw new Error(`expected 1 wei on-chain, got ${onChain}`);
  console.log("SMOKE OK");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
