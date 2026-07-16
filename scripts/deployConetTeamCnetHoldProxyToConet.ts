/**
 * Deploy ConetTeamCnetHold UUPS proxy on CoNET (224422), fund 1 CNET from
 * ValidatorDepositRedeem via withdrawNative, and smoke-test owner residual release.
 *
 * Run:
 *   npx hardhat run scripts/deployConetTeamCnetHoldProxyToConet.ts --network conet
 *
 * Then verify:
 *   node scripts/exportStandardJsonFromBuildInfo.mjs ConetTeamCnetHold --full
 *   npx tsx scripts/verifyConetTeamCnetHoldConet.ts
 *
 * Env (optional):
 *   CONET_TEAM_HOLD_OWNER / ADMIN / REDEEM_ADMIN
 *   CONET_TEAM_HOLD_START_TIMESTAMP — unix seconds (e.g. 1798675200 = 2026-12-31T00:00:00Z)
 *   CONET_TEAM_HOLD_SKIP_FUND=1
 *   CONET_TEAM_HOLD_SKIP_SMOKE=1 — also auto-skipped when start is still in the future
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import ERC1967ProxyArtifact from "@openzeppelin/contracts/build/contracts/ERC1967Proxy.json" with { type: "json" };

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const REDEEM = "0xc71e246DD78B37C2fABc905D340932F28F503433";
const FUND_WEI = ethers.parseEther("1");

function loadConetAddresses(): Record<string, unknown> {
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) return {};
  try {
    return JSON.parse(fs.readFileSync(addrPath, "utf-8")) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function envAddress(name: string): string | undefined {
  const raw = process.env[name]?.trim();
  if (raw && ethers.isAddress(raw)) return ethers.getAddress(raw);
  return undefined;
}

async function findRedeemAdminSigner(
  signers: Awaited<ReturnType<Awaited<ReturnType<typeof networkModule.connect>>["ethers"]["getSigners"]>>,
  provider: ethers.Provider
): Promise<(typeof signers)[number]> {
  const redeem = new ethers.Contract(
    REDEEM,
    ["function admins(address) view returns (bool)"],
    provider
  );
  for (const s of signers) {
    if (await redeem.admins(s.address)) return s;
  }
  throw new Error("No Hardhat conet signer is ValidatorDepositRedeem.admins(...)");
}

async function sleep(ms: number): Promise<void> {
  await new Promise((r) => setTimeout(r, ms));
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const signers = await ethersHH.getSigners();
  const deployer = signers[0];
  if (!deployer) throw new Error("no deployer");
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  const owner = envAddress("CONET_TEAM_HOLD_OWNER") ?? ethers.getAddress(deployer.address);
  const initialAdmin = envAddress("CONET_TEAM_HOLD_ADMIN") ?? owner;
  const initialRedeemAdmin = envAddress("CONET_TEAM_HOLD_REDEEM_ADMIN") ?? owner;

  const latest = await ethersHH.provider.getBlock("latest");
  const nowTs = BigInt(latest?.timestamp ?? Math.floor(Date.now() / 1000));
  const startEnv = process.env.CONET_TEAM_HOLD_START_TIMESTAMP?.trim();
  const startTimestamp = startEnv ? BigInt(startEnv) : nowTs;
  if (startTimestamp === 0n) throw new Error("startTimestamp must be > 0");

  console.log("=".repeat(60));
  console.log("Deploy ConetTeamCnetHold UUPS proxy on CoNET");
  console.log("=".repeat(60));
  console.log("deployer:", deployer.address);
  console.log("owner / admin / redeemAdmin:", owner, initialAdmin, initialRedeemAdmin);
  console.log("startTimestamp:", startTimestamp.toString(), `(${new Date(Number(startTimestamp) * 1000).toISOString()})`);
  if (startTimestamp > nowTs) {
    console.log("note: start is in the future — release smoke will be skipped");
  }
  console.log("balance:", ethers.formatEther(await ethersHH.provider.getBalance(deployer.address)), "CNET\n");

  const ImplFactory = await ethersHH.getContractFactory("ConetTeamCnetHold");
  const impl = await ImplFactory.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  const implTx = impl.deploymentTransaction()?.hash ?? "";
  console.log("implementation:", implAddr);
  if (implTx) console.log("  impl tx:", implTx);

  const initData = ImplFactory.interface.encodeFunctionData("initialize", [
    owner,
    startTimestamp,
    initialAdmin,
    initialRedeemAdmin,
  ]);

  const ProxyFactory = new ethers.ContractFactory(
    ERC1967ProxyArtifact.abi,
    ERC1967ProxyArtifact.bytecode,
    deployer
  );
  const proxy = await ProxyFactory.deploy(implAddr, initData);
  await proxy.waitForDeployment();
  const proxyAddr = await proxy.getAddress();
  const proxyDeployTx = proxy.deploymentTransaction();
  const proxyTxHash = proxyDeployTx?.hash ?? "";
  let proxyDeployBlock = 0;
  if (proxyDeployTx) {
    const receipt = await proxyDeployTx.wait();
    proxyDeployBlock = Number(receipt?.blockNumber ?? 0);
  }
  console.log("proxy (canonical):", proxyAddr);
  console.log("  proxy tx:", proxyTxHash);
  if (proxyDeployBlock) console.log("  proxy block:", proxyDeployBlock);

  const hold = ImplFactory.attach(proxyAddr) as Awaited<ReturnType<typeof ImplFactory.deploy>>;
  const readOwner = await (hold as unknown as { owner(): Promise<string> }).owner();
  const readStart = await (hold as unknown as { startTimestamp(): Promise<bigint> }).startTimestamp();
  console.log("readback owner:", readOwner);
  console.log("readback startTimestamp:", readStart.toString());
  if (ethers.getAddress(readOwner) !== owner) throw new Error("initialize failed: owner mismatch");
  if (readStart !== startTimestamp) throw new Error("initialize failed: startTimestamp mismatch");

  const addrData = loadConetAddresses();
  const out = {
    network: "conet",
    chainId: net.chainId.toString(),
    contract: "ConetTeamCnetHold",
    upgradeable: true,
    proxyPattern: "ERC1967Proxy",
    source: "src/mainnet/ConetTeamCnetHold.sol",
    address: proxyAddr,
    proxy: proxyAddr,
    implementation: implAddr,
    deployer: deployer.address,
    owner,
    initialAdmin,
    initialRedeemAdmin,
    startTimestamp: startTimestamp.toString(),
    initializeArgs: {
      owner,
      startTimestamp: startTimestamp.toString(),
      initialAdmin,
      initialRedeemAdmin,
    },
    compiler: "0.8.35+commit.47b9dedd",
    timestamp: new Date().toISOString(),
    deployBlock: proxyDeployBlock || undefined,
    transactionHash: proxyTxHash,
    implementationTransactionHash: implTx || undefined,
    fundFromRedeem: REDEEM,
    fundAmountWei: FUND_WEI.toString(),
  };

  const deploymentsDir = path.join(root, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });
  const outPath = path.join(deploymentsDir, "conet-ConetTeamCnetHold.json");

  // --- Fund 1 CNET from ValidatorDepositRedeem ---
  if (process.env.CONET_TEAM_HOLD_SKIP_FUND !== "1") {
    const redeemAdmin = await findRedeemAdminSigner(signers, ethersHH.provider);
    console.log("\nFund 1 CNET from ValidatorDepositRedeem via", redeemAdmin.address);
    const redeemBal = await ethersHH.provider.getBalance(REDEEM);
    console.log("redeem balance:", ethers.formatEther(redeemBal), "CNET");
    if (redeemBal < FUND_WEI) throw new Error("ValidatorDepositRedeem balance < 1 CNET");

    const redeem = new ethers.Contract(
      REDEEM,
      ["function withdrawNative(address to, uint256 amount) external"],
      redeemAdmin
    );
    const fundTx = await redeem.withdrawNative(proxyAddr, FUND_WEI);
    console.log("withdrawNative tx:", fundTx.hash);
    await fundTx.wait();
    (out as Record<string, unknown>).fundTx = fundTx.hash;

    const holdBal = await ethersHH.provider.getBalance(proxyAddr);
    console.log("hold balance after fund:", ethers.formatEther(holdBal), "CNET");
    if (holdBal < FUND_WEI) throw new Error("hold did not receive 1 CNET");
  }

  // --- Smoke: wait briefly then claim owner residual unlock ---
  const skipSmoke =
    process.env.CONET_TEAM_HOLD_SKIP_SMOKE === "1" || startTimestamp > nowTs;
  if (!skipSmoke) {
    console.log("\nSmoke: wait for linear unlock progress, then claimOwnerUnallocated");
    const holdAsOwner = hold.connect(
      signers.find((s) => ethers.getAddress(s.address) === owner) ?? deployer
    ) as typeof hold;

    let releasable = 0n;
    // 1 CNET / (36*30d) ≈ 1.07e10 wei/s — a few seconds unlocks non-zero releasable
    for (let i = 0; i < 8; i++) {
      await sleep(5_000);
      releasable = await (holdAsOwner as unknown as { ownerReleasable(): Promise<bigint> }).ownerReleasable();
      const unalloc = await (holdAsOwner as unknown as { unallocated(): Promise<bigint> }).unallocated();
      console.log(
        `  tick ${i + 1}: unallocated=${ethers.formatEther(unalloc)} ownerReleasable=${releasable.toString()} wei`
      );
      if (releasable > 0n) break;
    }
    if (releasable === 0n) {
      throw new Error("ownerReleasable still 0 after wait — vesting start / clock check failed");
    }

    const ownerBefore = await ethersHH.provider.getBalance(owner);
    const claimTx = await (
      holdAsOwner as unknown as {
        claimOwnerUnallocated: (a: bigint) => Promise<ethers.ContractTransactionResponse>;
      }
    ).claimOwnerUnallocated(releasable);
    console.log("claimOwnerUnallocated tx:", claimTx.hash);
    const claimRc = await claimTx.wait();
    if (claimRc?.status !== 1) throw new Error("claimOwnerUnallocated failed");

    const ownerReleased = await (
      holdAsOwner as unknown as { ownerReleased(): Promise<bigint> }
    ).ownerReleased();
    const holdBalAfter = await ethersHH.provider.getBalance(proxyAddr);
    const ownerAfter = await ethersHH.provider.getBalance(owner);
    console.log("ownerReleased:", ownerReleased.toString(), "wei");
    console.log("hold balance after claim:", ethers.formatEther(holdBalAfter), "CNET");
    console.log(
      "owner delta (gross, before gas if owner==claimer):",
      ethers.formatEther(ownerAfter - ownerBefore),
      "CNET"
    );
    if (ownerReleased < releasable) throw new Error("ownerReleased did not increase as expected");
    (out as Record<string, unknown>).smoke = {
      claimedWei: releasable.toString(),
      claimTx: claimTx.hash,
      ownerReleased: ownerReleased.toString(),
      holdBalanceAfter: holdBalAfter.toString(),
    };
    console.log("✅ release smoke OK");
  }

  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf-8");
  console.log("\nsaved:", outPath);

  const merged = { ...addrData, ConetTeamCnetHold: proxyAddr };
  const addrPath = path.join(deploymentsDir, "conet-addresses.json");
  fs.writeFileSync(addrPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
  console.log("updated:", addrPath, "→ ConetTeamCnetHold =", proxyAddr);

  console.log("\n下一步验证:");
  console.log("  node scripts/exportStandardJsonFromBuildInfo.mjs ConetTeamCnetHold --full");
  console.log("  npx tsx scripts/verifyConetTeamCnetHoldConet.ts");
  console.log("\n查看: https://mainnet.conet.network/address/" + proxyAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
