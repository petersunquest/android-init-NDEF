import { network as networkModule } from "hardhat";

async function main() {
  const { ethers } = await networkModule.connect();
  const B = "0x2D318c674F1716264c78B1D33e18E3F8cb02fCE8";
  const W0 = "0xcbBB1371973D57e6bD45aC0dfeFD493b59F9D76B";
  const W1 = "0x6bF3Aa7261e21Be5Fc781Ac09F9475c8A34AfEea";

  const Gb = await ethers.getContractFactory("MockGbZero");
  const gb = await Gb.deploy();
  await gb.waitForDeployment();
  const Idx = await ethers.getContractFactory("MockIdxZero");
  const idx = await Idx.deploy();
  await idx.waitForDeployment();
  const Reader = await ethers.getContractFactory("MockUnifiedReader");
  const reader = await Reader.deploy(
    await gb.getAddress(),
    await idx.getAddress(),
    B,
    W0,
    W1
  );
  await reader.waitForDeployment();

  const Lib = await ethers.getContractFactory("ValidatorDepositRedeemStatsLib");
  const lib = await Lib.deploy();
  await lib.waitForDeployment();
  console.log("lib:", await lib.getAddress(), "reader:", await reader.getAddress());

  const libAt = await ethers.getContractAt(
    "ValidatorDepositRedeemStatsLib",
    await lib.getAddress()
  );

  const nb = await reader.resolveNodeBundle(B, "");
  console.log("reader bundle nodeWallets:", nb.nodeWallets, "ids:", nb.guardianNodeIds.map((x: bigint) => x.toString()));

  try {
    const r = await libAt.resolveUnifiedFromRedeem(await reader.getAddress(), B, "", 0n);
    console.log("resolveUnifiedFromRedeem OK, nodes:", r.nodes.length);
    for (const n of r.nodes) console.log("  node", n.nodeWallet, n.depinNodeIp);
  } catch (e: any) {
    console.log("resolveUnifiedFromRedeem REVERT:", e.shortMessage || e.message);
    if (e.data) console.log("  data:", e.data);
    console.log((e.stack || "").split("\n").slice(0, 10).join("\n"));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
