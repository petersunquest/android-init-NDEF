/**
 * Smoke: temporarily set feeSettlement to signer, mint 0.001 V3 USDC to Airdrop, restore.
 *
 * Usage:
 *   npx hardhat run scripts/smokeTreasuryV3FeeMintConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const BRIDGE = "0xa208982212978550594A7FEEB70a61665d129003";
const V3 = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";
const AIRDROP = "0x305f90A7f38289219BA1b4be98CB5b47e7b15Ac2";
const LEGACY = "0xfD0D7B0706AaB5E4351bcED37bC3C77ed6813907";

async function main() {
  const { ethers } = await networkModule.connect();
  const network = await ethers.provider.getNetwork();
  if (Number(network.chainId) !== 224422) {
    throw new Error(`Expected CoNET 224422, got ${network.chainId}`);
  }

  const signers = await ethers.getSigners();
  const signer = signers[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);

  const bridge = new ethers.Contract(
    BRIDGE,
    [
      "function setFeeSettlement(address,address)",
      "function feeSettlement() view returns (address)",
      "function mintForAdmin(address,address,uint256)",
    ],
    signer,
  );
  const v3 = new ethers.Contract(
    V3,
    ["function totalSupply() view returns (uint256)", "function balanceOf(address) view returns (uint256)"],
    signer,
  );
  const legacy = new ethers.Contract(LEGACY, ["function totalSupply() view returns (uint256)"], signer);

  const beforeV3 = await v3.totalSupply();
  const beforeLegacy = await legacy.totalSupply();
  const beforeBal = await v3.balanceOf(AIRDROP);

  const set1 = await bridge.setFeeSettlement(signer.address, V3);
  await set1.wait();

  const amount = 1_000n;
  const mintTx = await bridge.mintForAdmin(V3, AIRDROP, amount);
  await mintTx.wait();

  const set2 = await bridge.setFeeSettlement(AIRDROP, V3);
  await set2.wait();

  const afterV3 = await v3.totalSupply();
  const afterLegacy = await legacy.totalSupply();
  const afterBal = await v3.balanceOf(AIRDROP);

  const result = {
    mintTx: mintTx.hash,
    amount: amount.toString(),
    beforeV3: beforeV3.toString(),
    afterV3: afterV3.toString(),
    v3Delta: (afterV3 - beforeV3).toString(),
    beforeLegacy: beforeLegacy.toString(),
    afterLegacy: afterLegacy.toString(),
    legacyUnchanged: afterLegacy === beforeLegacy,
    airdropV3BalanceBefore: beforeBal.toString(),
    airdropV3BalanceAfter: afterBal.toString(),
    feeSettlement: await bridge.feeSettlement(),
    ok: afterV3 - beforeV3 === amount && afterLegacy === beforeLegacy,
  };
  console.log(JSON.stringify(result, null, 2));
  if (!result.ok) throw new Error("Smoke mint failed");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
