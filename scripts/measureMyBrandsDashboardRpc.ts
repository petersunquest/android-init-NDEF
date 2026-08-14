/**
 * Measure My Brands Dashboard eth_call budget.
 *
 *   npx tsx scripts/measureMyBrandsDashboardRpc.ts
 *   EOAs=0x... CARDS=0x...,0x... npx tsx scripts/measureMyBrandsDashboardRpc.ts
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const DASH_OUT = path.join(ROOT, "deployments", "conet-BeamioMyBrandsDashboard.json");
const RPC = process.env.CONET_RPC_URL || "https://rpc1.conet.network";

const SNAPSHOT_ABI = [
  `function snapshotCards(address[] cards, address eoa, address aaOptional, uint256 rewardTokenId) view returns (
    tuple(
      address card,
      bool ok,
      uint8 currency,
      address owner,
      uint256 points,
      uint256 rewardBalance,
      tuple(uint256 tokenId, uint256 attribute, uint256 tierIndexOrMax, uint256 expiry, bool isExpired)[] membershipNfts,
      uint256[28] statBalancesEoa,
      uint256[28] statBalancesAa,
      bool hasAnyProgramAsset
    )[] slices
  )`,
];

async function main() {
  const dash = JSON.parse(fs.readFileSync(DASH_OUT, "utf-8")) as { proxy: string };
  const proxy = dash.proxy;
  const eoa = process.env.EOA || "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
  const cardsEnv = process.env.CARDS || "";
  const cards = cardsEnv
    .split(",")
    .map((s) => s.trim())
    .filter((s) => ethers.isAddress(s))
    .map((s) => ethers.getAddress(s));

  const provider = new ethers.JsonRpcProvider(RPC, 224422, { staticNetwork: true, batchMaxCount: 1 });
  let ethCallCount = 0;
  const origSend = provider.send.bind(provider);
  provider.send = async (method: string, params: Array<unknown>) => {
    if (method === "eth_call") ethCallCount++;
    return origSend(method, params);
  };

  const c = new ethers.Contract(proxy, SNAPSHOT_ABI, provider);
  console.log("proxy:", proxy);
  console.log("eoa:", eoa);
  console.log("cards:", cards.length ? cards : "(empty)");

  ethCallCount = 0;
  const t0 = Date.now();
  const slices = await c.snapshotCards(cards, eoa, ethers.ZeroAddress, 2n);
  const ms = Date.now() - t0;
  console.log("snapshotCards eth_call count:", ethCallCount);
  console.log("latency ms:", ms);
  console.log("slices:", slices.length);
  for (const s of slices) {
    console.log({
      card: s.card,
      ok: s.ok,
      currency: Number(s.currency),
      points: s.points.toString(),
      reward: s.rewardBalance.toString(),
      nfts: s.membershipNfts.length,
      hasAny: s.hasAnyProgramAsset,
    });
  }

  const notePath = path.join(ROOT, "deployments", "conet-BeamioMyBrandsDashboard-rpc-budget.md");
  fs.writeFileSync(
    notePath,
    [
      "# BeamioMyBrandsDashboard RPC budget",
      "",
      `- Proxy: \`${proxy}\``,
      `- Measured: ${new Date().toISOString()}`,
      `- EOA: \`${eoa}\``,
      `- Cards in call: ${cards.length}`,
      `- \`snapshotCards\` eth_call count: **${ethCallCount}** (expected 1)`,
      `- Latency: ${ms} ms`,
      "",
      "SilentPassUI My Brands feeder uses this for display-card assets; coupon filter uses `balanceBatch` (1 eth_call per card with known tokenIds).",
      "",
    ].join("\n"),
    "utf-8",
  );
  console.log("wrote", notePath);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
