/**
 * Upgrade TreasuryBridgeV3 + Canonical USDC + TGB5 with offline-sign paths,
 * register managed assets, grant GB/BUint admin to treasury (no token upgrade),
 * then Beamio_Manager offline-signs payAndMint: 0.1 conet-USDC → 0.1 TGB5.
 */
import { ethers } from "ethers";
import fs from "fs";
import path from "path";
import os from "os";
const RPC = process.env.CONET_RPC_URL || "https://rpc1.conet.network";
const CHAIN_ID = 224422n;
const TREASURY = "0xa208982212978550594A7FEEB70a61665d129003";
const USDC = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";
const TGB5 = "0xEb8c8b0f4e3f779D8A8d863580AaaD72AFebe242";
const TEST_USER = "0x82DADaeC25bebB58D6FaD2B91f394Ad10A9b0eE1";

const USDC_AMOUNT = ethers.parseUnits("0.1", 6);
const TGB5_AMOUNT = ethers.parseUnits("0.1", 18);

function loadArtifact(solRelative: string, contractName: string) {
  const p = path.join(
    process.cwd(),
    "artifacts",
    "src",
    "b-unit",
    solRelative,
    `${contractName}.json`,
  );
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

async function main() {
  const master = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".master.json"), "utf8"));
  let userPk = master.Beamio_Manager as string;
  if (!userPk.startsWith("0x")) userPk = "0x" + userPk;
  let adminPk = master.settle_contractAdmin[0] as string;
  if (!adminPk.startsWith("0x")) adminPk = "0x" + adminPk;

  const provider = new ethers.JsonRpcProvider(RPC);
  const net = await provider.getNetwork();
  if (net.chainId !== CHAIN_ID) throw new Error(`chainId ${net.chainId} != ${CHAIN_ID}`);

  const user = new ethers.Wallet(userPk, provider);
  const admin = new ethers.Wallet(adminPk, provider);
  if (user.address.toLowerCase() !== TEST_USER.toLowerCase()) {
    throw new Error(`Beamio_Manager ${user.address} != ${TEST_USER}`);
  }

  const addressesPath = path.join(process.cwd(), "deployments", "conet-addresses.json");
  const addresses = JSON.parse(fs.readFileSync(addressesPath, "utf8"));
  const GB = addresses.GBToken as string;
  const BUINT = addresses.BUint as string;

  console.log("============================================================");
  console.log("Upgrade treasury offline-sign + payAndMint 0.1 USDC → 0.1 TGB5");
  console.log("============================================================");
  console.log({ admin: admin.address, user: user.address, treasury: TREASURY });

  const treasuryArt = loadArtifact("TreasuryBridgeV3.sol", "TreasuryBridgeV3");
  const canonicalArt = loadArtifact("TreasuryCanonicalERC20V3.sol", "TreasuryCanonicalERC20V3");

  // --- deploy new impls ---
  console.log("[1] deploy TreasuryBridgeV3 impl");
  const TreasFactory = new ethers.ContractFactory(treasuryArt.abi, treasuryArt.bytecode, admin);
  const treasImpl = await TreasFactory.deploy();
  await treasImpl.waitForDeployment();
  const treasImplAddr = await treasImpl.getAddress();
  console.log("    impl", treasImplAddr);

  console.log("[2] deploy TreasuryCanonicalERC20V3 impl");
  const CanonFactory = new ethers.ContractFactory(canonicalArt.abi, canonicalArt.bytecode, admin);
  const canonImpl = await CanonFactory.deploy();
  await canonImpl.waitForDeployment();
  const canonImplAddr = await canonImpl.getAddress();
  console.log("    impl", canonImplAddr);

  const uupsAbi = [
    "function upgradeToAndCall(address,bytes)",
    "function owner() view returns (address)",
    "function hasRole(bytes32,address) view returns (bool)",
    "function DEFAULT_ADMIN_ROLE() view returns (bytes32)",
  ];

  console.log("[3] upgrade TreasuryBridgeV3 proxy");
  const treasuryOwner = new ethers.Contract(TREASURY, uupsAbi, admin);
  const tOwner = await treasuryOwner.owner();
  if (tOwner.toLowerCase() !== admin.address.toLowerCase()) {
    throw new Error(`treasury owner ${tOwner} != admin`);
  }
  let tx = await treasuryOwner.upgradeToAndCall(treasImplAddr, "0x");
  await tx.wait();
  console.log("    tx", tx.hash);

  console.log("[4] upgrade conet-USDC + TGB5 Canonical proxies");
  for (const [label, proxy] of [
    ["USDC", USDC],
    ["TGB5", TGB5],
  ] as const) {
    const c = new ethers.Contract(proxy, uupsAbi, admin);
    const role = await c.DEFAULT_ADMIN_ROLE();
    if (!(await c.hasRole(role, admin.address))) {
      throw new Error(`${label} admin missing`);
    }
    tx = await c.upgradeToAndCall(canonImplAddr, "0x");
    await tx.wait();
    console.log(`    ${label} upgraded`, tx.hash);
  }

  const treasury = new ethers.Contract(TREASURY, treasuryArt.abi, admin);
  const usdc = new ethers.Contract(USDC, canonicalArt.abi, provider);
  const tgb5 = new ethers.Contract(TGB5, canonicalArt.abi, provider);

  // Kind: Canonical=1, GbPaid=2, BUnitPaid=3
  console.log("[5] setTreasuryAssetKind USDC/TGB5/GB/BUint");
  for (const [asset, kind, name] of [
    [USDC, 1, "USDC Canonical"],
    [TGB5, 1, "TGB5 Canonical"],
    [GB, 2, "GB GbPaid"],
    [BUINT, 3, "BUint BUnitPaid"],
  ] as const) {
    const cur = await treasury.treasuryAssetKind(asset);
    if (Number(cur) !== kind) {
      tx = await treasury.setTreasuryAssetKind(asset, kind);
      await tx.wait();
      console.log(`    ${name} kind=${kind}`, tx.hash);
    } else {
      console.log(`    ${name} already kind=${kind}`);
    }
  }

  console.log("[6] authorize TGB5 bridge asset + ensure TREASURY_ROLE");
  if (!(await treasury.authorizedBridgeAsset(TGB5))) {
    tx = await treasury.setBridgeAssetAuthorization(TGB5, true);
    await tx.wait();
    console.log("    auth TGB5", tx.hash);
  }
  const TREASURY_ROLE = ethers.id("TREASURY_ROLE");
  const tgb5Admin = new ethers.Contract(
    TGB5,
    ["function hasRole(bytes32,address) view returns (bool)", "function setTreasury(address)"],
    admin,
  );
  if (!(await tgb5Admin.hasRole(TREASURY_ROLE, TREASURY))) {
    tx = await tgb5Admin.setTreasury(TREASURY);
    await tx.wait();
    console.log("    TGB5 setTreasury", tx.hash);
  }

  // GB / BUint: addAdmin(treasury) — no upgrade
  console.log("[7] GB/BUint addAdmin(treasury) if needed");
  const adminTokenAbi = [
    "function admins(address) view returns (bool)",
    "function addAdmin(address)",
    "function isAdmin(address) view returns (bool)",
  ];
  for (const [label, addr] of [
    ["GB", GB],
    ["BUint", BUINT],
  ] as const) {
    const tok = new ethers.Contract(addr, adminTokenAbi, admin);
    let isAdm = false;
    try {
      isAdm = await tok.admins(TREASURY);
    } catch {
      try {
        isAdm = await tok.isAdmin(TREASURY);
      } catch {
        /* ignore */
      }
    }
    if (!isAdm) {
      try {
        tx = await tok.addAdmin(TREASURY);
        await tx.wait();
        console.log(`    ${label} addAdmin`, tx.hash);
      } catch (e: any) {
        console.log(`    ${label} addAdmin skip/fail:`, e.shortMessage || e.message);
      }
    } else {
      console.log(`    ${label} treasury already admin`);
    }
  }

  // --- offline payAndMint ---
  console.log("[8] Beamio_Manager offline sign payAndMint 0.1 USDC → 0.1 TGB5");
  const beforeUsdc = await usdc.balanceOf(user.address);
  const beforeTgb5 = await tgb5.balanceOf(user.address);
  console.log("    before", {
    usdc: ethers.formatUnits(beforeUsdc, 6),
    tgb5: ethers.formatUnits(beforeTgb5, 18),
  });
  if (beforeUsdc < USDC_AMOUNT) throw new Error("user needs ≥0.1 USDC");

  const opNonce = await treasury.treasuryAssetOpNonces(user.address);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const validAfter = 0n;
  const validBefore = deadline;
  const paymentNonce = ethers.hexlify(ethers.randomBytes(32));

  // EIP-3009 on USDC (domain = token name())
  const usdcName = await usdc.name();
  const paymentSig = await user.signTypedData(
    {
      name: usdcName,
      version: "1",
      chainId: CHAIN_ID,
      verifyingContract: USDC,
    },
    {
      TransferWithAuthorization: [
        { name: "from", type: "address" },
        { name: "to", type: "address" },
        { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce", type: "bytes32" },
      ],
    },
    {
      from: user.address,
      to: TREASURY,
      value: USDC_AMOUNT,
      validAfter,
      validBefore,
      nonce: paymentNonce,
    },
  );

  const opSig = await user.signTypedData(
    {
      name: "TreasuryBridgeV3",
      version: "1",
      chainId: CHAIN_ID,
      verifyingContract: TREASURY,
    },
    {
      PayAndMint: [
        { name: "signer", type: "address" },
        { name: "paymentAsset", type: "address" },
        { name: "paymentAmount", type: "uint256" },
        { name: "mintAsset", type: "address" },
        { name: "mintAmount", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    {
      signer: user.address,
      paymentAsset: USDC,
      paymentAmount: USDC_AMOUNT,
      mintAsset: TGB5,
      mintAmount: TGB5_AMOUNT,
      nonce: opNonce,
      deadline,
    },
  );

  console.log("[9] relayer (admin) submits payAndMintWithSignature — user pays 0 CNET gas");
  const treasuryAsRelayer = treasury.connect(admin) as typeof treasury;
  tx = await treasuryAsRelayer.payAndMintWithSignature(
    user.address,
    USDC,
    USDC_AMOUNT,
    TGB5,
    TGB5_AMOUNT,
    validAfter,
    validBefore,
    paymentNonce,
    paymentSig,
    opNonce,
    deadline,
    opSig,
  );
  const receipt = await tx.wait();
  console.log("    tx", tx.hash, "status", receipt?.status);

  const afterUsdc = await usdc.balanceOf(user.address);
  const afterTgb5 = await tgb5.balanceOf(user.address);
  console.log("[10] after", {
    usdc: ethers.formatUnits(afterUsdc, 6),
    tgb5: ethers.formatUnits(afterTgb5, 18),
    usdcDelta: ethers.formatUnits(beforeUsdc - afterUsdc, 6),
    tgb5Delta: ethers.formatUnits(afterTgb5 - beforeTgb5, 18),
  });

  if (beforeUsdc - afterUsdc !== USDC_AMOUNT) throw new Error("USDC debit mismatch");
  if (afterTgb5 - beforeTgb5 !== TGB5_AMOUNT) throw new Error("TGB5 mint mismatch");

  const out = {
    network: "conet",
    chainId: CHAIN_ID.toString(),
    timestamp: new Date().toISOString(),
    treasuryImpl: treasImplAddr,
    canonicalImpl: canonImplAddr,
    payAndMintTx: tx.hash,
    user: user.address,
    usdcPaid: USDC_AMOUNT.toString(),
    tgb5Minted: TGB5_AMOUNT.toString(),
  };
  const outPath = path.join(process.cwd(), "deployments", "conet-treasury-offline-payAndMint.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");

  addresses.TreasuryBridgeV3Impl = treasImplAddr;
  addresses.conetUsdcImpl = canonImplAddr;
  addresses.TestDeveloperFxERC20Impl = canonImplAddr;
  fs.writeFileSync(addressesPath, JSON.stringify(addresses, null, 2) + "\n");
  console.log("[11] wrote", outPath);
  console.log("============================================================");
  console.log("DONE — offline payAndMint OK (user gasless)");
  console.log("============================================================");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
