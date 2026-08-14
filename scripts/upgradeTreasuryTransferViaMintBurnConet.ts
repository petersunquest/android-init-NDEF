/**
 * Upgrade TreasuryBridgeV3 with transferViaMintBurnWithSignature, then smoke-test:
 * Beamio_Manager offline-signs transfer of 0.05 TGB5 → settle admin (relayer pays gas).
 */
import { ethers } from "ethers";
import fs from "fs";
import path from "path";
import os from "os";

const RPC = process.env.CONET_RPC_URL || "https://rpc1.conet.network";
const CHAIN_ID = 224422n;
const TREASURY = "0xa208982212978550594A7FEEB70a61665d129003";
const TGB5 = "0xEb8c8b0f4e3f779D8A8d863580AaaD72AFebe242";
const TEST_USER = "0x82DADaeC25bebB58D6FaD2B91f394Ad10A9b0eE1";
const AMOUNT = ethers.parseUnits("0.05", 18);

function loadArtifact(solRelative: string, contractName: string) {
  const p = path.join(process.cwd(), "artifacts", "src", "b-unit", solRelative, `${contractName}.json`);
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

async function main() {
  const master = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".master.json"), "utf8"));
  let userPk = master.Beamio_Manager as string;
  if (!userPk.startsWith("0x")) userPk = "0x" + userPk;
  let adminPk = master.settle_contractAdmin[0] as string;
  if (!adminPk.startsWith("0x")) adminPk = "0x" + adminPk;

  const provider = new ethers.JsonRpcProvider(RPC);
  const user = new ethers.Wallet(userPk, provider);
  const admin = new ethers.Wallet(adminPk, provider);
  if (user.address.toLowerCase() !== TEST_USER.toLowerCase()) {
    throw new Error(`Beamio_Manager ${user.address} != ${TEST_USER}`);
  }

  console.log("============================================================");
  console.log("Upgrade treasury + transferViaMintBurnWithSignature smoke");
  console.log("============================================================");

  const art = loadArtifact("TreasuryBridgeV3.sol", "TreasuryBridgeV3");
  const Factory = new ethers.ContractFactory(art.abi, art.bytecode, admin);
  console.log("[1] deploy TreasuryBridgeV3 impl");
  const impl = await Factory.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  console.log("    impl", implAddr);

  const proxy = new ethers.Contract(
    TREASURY,
    ["function upgradeToAndCall(address,bytes)", "function owner() view returns (address)"],
    admin,
  );
  console.log("[2] upgradeToAndCall");
  let tx = await proxy.upgradeToAndCall(implAddr, "0x");
  await tx.wait();
  console.log("    tx", tx.hash);

  const treasury = new ethers.Contract(TREASURY, art.abi, admin);
  const tgb5 = new ethers.Contract(
    TGB5,
    ["function balanceOf(address) view returns (uint256)", "function symbol() view returns (string)"],
    provider,
  );

  // sanity: typehash exists
  const th = await treasury.TRANSFER_VIA_MINT_BURN_TYPEHASH();
  console.log("[3] TRANSFER_VIA_MINT_BURN_TYPEHASH", th);

  const beforeFrom = await tgb5.balanceOf(user.address);
  const beforeTo = await tgb5.balanceOf(admin.address);
  console.log("[4] before", {
    from: ethers.formatUnits(beforeFrom, 18),
    to: ethers.formatUnits(beforeTo, 18),
  });
  if (beforeFrom < AMOUNT) throw new Error("user needs ≥0.05 TGB5");

  const nonce = await treasury.treasuryAssetOpNonces(user.address);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const sig = await user.signTypedData(
    {
      name: "TreasuryBridgeV3",
      version: "1",
      chainId: CHAIN_ID,
      verifyingContract: TREASURY,
    },
    {
      TransferViaMintBurn: [
        { name: "signer", type: "address" },
        { name: "asset", type: "address" },
        { name: "to", type: "address" },
        { name: "amount", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    {
      signer: user.address,
      asset: TGB5,
      to: admin.address,
      amount: AMOUNT,
      nonce,
      deadline,
    },
  );

  console.log("[5] relayer submits transferViaMintBurnWithSignature (0.05 TGB5 → admin)");
  tx = await treasury.transferViaMintBurnWithSignature(
    user.address,
    TGB5,
    admin.address,
    AMOUNT,
    nonce,
    deadline,
    sig,
  );
  const rc = await tx.wait();
  console.log("    tx", tx.hash, "status", rc?.status);

  const afterFrom = await tgb5.balanceOf(user.address);
  const afterTo = await tgb5.balanceOf(admin.address);
  console.log("[6] after", {
    from: ethers.formatUnits(afterFrom, 18),
    to: ethers.formatUnits(afterTo, 18),
    fromDelta: ethers.formatUnits(beforeFrom - afterFrom, 18),
    toDelta: ethers.formatUnits(afterTo - beforeTo, 18),
  });
  if (beforeFrom - afterFrom !== AMOUNT) throw new Error("from delta mismatch");
  if (afterTo - beforeTo !== AMOUNT) throw new Error("to delta mismatch");

  const addressesPath = path.join(process.cwd(), "deployments", "conet-addresses.json");
  const addresses = JSON.parse(fs.readFileSync(addressesPath, "utf8"));
  addresses.TreasuryBridgeV3Impl = implAddr;
  fs.writeFileSync(addressesPath, JSON.stringify(addresses, null, 2) + "\n");

  const out = {
    network: "conet",
    chainId: CHAIN_ID.toString(),
    timestamp: new Date().toISOString(),
    treasuryImpl: implAddr,
    transferTx: tx.hash,
    from: user.address,
    to: admin.address,
    asset: TGB5,
    amount: AMOUNT.toString(),
  };
  const outPath = path.join(process.cwd(), "deployments", "conet-treasury-transferViaMintBurn.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log("[7] wrote", outPath);
  console.log("============================================================");
  console.log("DONE — transferViaMintBurnWithSignature OK");
  console.log("============================================================");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
