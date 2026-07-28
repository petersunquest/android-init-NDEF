/**
 * Upgrade ReferralRegistryVaultV1 to direct-pay rebates (no claim queue).
 * Then mint enough V3 USDC onto Airdrop to cover reservedClaimable and flush pending claimable EOAs.
 *
 * Usage:
 *   npx hardhat run scripts/upgradeReferralVaultDirectPayConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const VAULT = "0xD6252Cbf266B80231397Ac2a4f25ed2d9b01DEE6";
const AIRDROP = "0x305f90A7f38289219BA1b4be98CB5b47e7b15Ac2";
const BRIDGE = "0xa208982212978550594A7FEEB70a61665d129003";
const V3 = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";
const IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

async function main() {
  const { ethers } = await networkModule.connect();
  const network = await ethers.provider.getNetwork();
  if (Number(network.chainId) !== 224422) {
    throw new Error(`Expected CoNET 224422, got ${network.chainId}`);
  }

  const signers = await ethers.getSigners();
  const signer = signers[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);
  console.log("signer", signer.address);

  const vault = new ethers.Contract(
    VAULT,
    [
      "function owner() view returns (address)",
      "function conetUsdc() view returns (address)",
      "function bunitAirdrop() view returns (address)",
      "function claimableConetUsdc(address) view returns (uint256)",
      "function claimedConetUsdc(address) view returns (uint256)",
      "function flushPendingClaimable(address)",
      "function upgradeToAndCall(address newImplementation, bytes data) payable",
    ],
    signer,
  );

  const owner = await vault.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer ${signer.address} is not vault owner ${owner}`);
  }

  const beforeImpl = ethers.getAddress(
    "0x" + (await ethers.provider.getStorage(VAULT, IMPLEMENTATION_SLOT)).slice(-40),
  );
  console.log("beforeImpl", beforeImpl);
  console.log("vault.conetUsdc", await vault.conetUsdc());

  // 1) Deploy libraries + new impl
  const PackageLib = await ethers.getContractFactory("ReferralRegistryPackageClaimLib", signer);
  const packageLib = await PackageLib.deploy();
  await packageLib.waitForDeployment();
  const packageLibAddr = await packageLib.getAddress();
  await packageLib.deploymentTransaction()!.wait();

  const SettlementLib = await ethers.getContractFactory("ReferralRegistrySettlementLib", signer);
  const settlementLib = await SettlementLib.deploy();
  await settlementLib.waitForDeployment();
  const settlementLibAddr = await settlementLib.getAddress();
  await settlementLib.deploymentTransaction()!.wait();

  const VaultFactory = await ethers.getContractFactory("ReferralRegistryVaultV1", {
    signer,
    libraries: {
      ReferralRegistryPackageClaimLib: packageLibAddr,
      ReferralRegistrySettlementLib: settlementLibAddr,
    },
  });
  const newImpl = await VaultFactory.deploy();
  await newImpl.waitForDeployment();
  const newImplAddr = await newImpl.getAddress();
  const implDeployTx = newImpl.deploymentTransaction();
  await implDeployTx!.wait();
  console.log({ packageLibAddr, settlementLibAddr, newImplAddr, implDeployTx: implDeployTx!.hash });

  const upgradeTx = await vault.upgradeToAndCall(newImplAddr, "0x");
  await upgradeTx.wait();
  const afterImpl = ethers.getAddress(
    "0x" + (await ethers.provider.getStorage(VAULT, IMPLEMENTATION_SLOT)).slice(-40),
  );
  if (afterImpl.toLowerCase() !== newImplAddr.toLowerCase()) {
    throw new Error(`Upgrade failed: impl=${afterImpl}`);
  }
  console.log("upgraded", upgradeTx.hash);

  // 2) Collect pending claimable accounts from ClaimableAccrued logs
  const accruedTopic = ethers.id("ClaimableAccrued(bytes32,address,uint256)");
  const pending = new Map<string, bigint>();
  const latest = await ethers.provider.getBlockNumber();
  for (let s = 431457; s <= latest; s += 20_000) {
    const e = Math.min(s + 19_999, latest);
    let logs: any[] = [];
    try {
      logs = await ethers.provider.getLogs({
        address: VAULT,
        fromBlock: s,
        toBlock: e,
        topics: [accruedTopic],
      });
    } catch {
      continue;
    }
    for (const log of logs) {
      const account = ethers.getAddress("0x" + log.topics[2].slice(26));
      pending.set(account, 0n);
    }
  }

  const toFlush: { account: string; amount: bigint }[] = [];
  for (const account of pending.keys()) {
    const amount = await vault.claimableConetUsdc(account);
    if (amount > 0n) toFlush.push({ account, amount });
  }
  const flushTotal = toFlush.reduce((a, x) => a + x.amount, 0n);
  console.log(
    "pendingFlush",
    toFlush.map((x) => ({ account: x.account, amount: x.amount.toString() })),
    "total",
    flushTotal.toString(),
  );

  const airdrop = new ethers.Contract(
    AIRDROP,
    [
      "function reservedClaimableUsdc() view returns (uint256)",
      "function conetUsdc() view returns (address)",
    ],
    signer,
  );
  const v3 = new ethers.Contract(
    V3,
    ["function balanceOf(address) view returns (uint256)"],
    signer,
  );
  const reserved = await airdrop.reservedClaimableUsdc();
  const airdropBal = await v3.balanceOf(AIRDROP);
  console.log({ reserved: reserved.toString(), airdropBal: airdropBal.toString() });

  // Fund V3 so airdrop can payout reserved/flushTotal
  const need = reserved > airdropBal ? reserved - airdropBal : 0n;
  let fundTxHash: string | null = null;
  if (need > 0n || flushTotal > airdropBal) {
    const mintAmount = need > 0n ? need : flushTotal - airdropBal;
    const bridge = new ethers.Contract(
      BRIDGE,
      [
        "function setFeeSettlement(address,address)",
        "function feeSettlement() view returns (address)",
        "function mintForAdmin(address,address,uint256)",
      ],
      signer,
    );
    const set1 = await bridge.setFeeSettlement(signer.address, V3);
    await set1.wait();
    const mintTx = await bridge.mintForAdmin(V3, AIRDROP, mintAmount);
    await mintTx.wait();
    fundTxHash = mintTx.hash;
    const set2 = await bridge.setFeeSettlement(AIRDROP, V3);
    await set2.wait();
    console.log("fundedV3", { mintAmount: mintAmount.toString(), fundTxHash });
  }

  // 3) Flush each pending claimable to EOA
  const flushTxs: { account: string; amount: string; tx: string }[] = [];
  for (const { account, amount } of toFlush) {
    const tx = await vault.flushPendingClaimable(account);
    await tx.wait();
    flushTxs.push({ account, amount: amount.toString(), tx: tx.hash });
    const left = await vault.claimableConetUsdc(account);
    if (left !== 0n) throw new Error(`flush incomplete for ${account}: ${left}`);
  }

  const out = {
    network: "conet",
    chainId: 224422,
    vault: VAULT,
    beforeImpl,
    afterImpl,
    packageLib: packageLibAddr,
    settlementLib: settlementLibAddr,
    upgradeTx: upgradeTx.hash,
    fundTxHash,
    reservedAfter: (await airdrop.reservedClaimableUsdc()).toString(),
    airdropV3After: (await v3.balanceOf(AIRDROP)).toString(),
    flushTxs,
    note: "New paid B-Unit burns mint V3 USDC then direct-pay L0/L1 EOAs; claimConetUsdc removed from impl.",
  };
  const outPath = path.join(ROOT, "deployments/conet-referral-vault-direct-pay.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log(JSON.stringify(out, null, 2));
  console.log("wrote", outPath);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
