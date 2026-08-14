import { ethers } from "ethers";
import fs from "fs";
import path from "path";
import os from "os";

async function main() {
  const RPC = "https://rpc1.conet.network";
  const USDC = "0x5209865D404aA5646eDe5B91CD4218909eA72eDA";
  const TGB5 = "0xEb8c8b0f4e3f779D8A8d863580AaaD72AFebe242";
  const TREAS = "0xa208982212978550594A7FEEB70a61665d129003";
  const USER = "0x82DADaeC25bebB58D6FaD2B91f394Ad10A9b0eE1";

  const master = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".master.json"), "utf8"));
  let pk = master.Beamio_Manager as string;
  if (!pk.startsWith("0x")) pk = "0x" + pk;
  const w = new ethers.Wallet(pk);
  console.log("derived", w.address);
  console.log("matches", w.address.toLowerCase() === USER.toLowerCase());

  const p = new ethers.JsonRpcProvider(RPC);
  const erc20 = [
    "function balanceOf(address) view returns (uint256)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
    "function hasRole(bytes32,address) view returns (bool)",
    "function BRIDGE_ROLE() view returns (bytes32)",
    "function TREASURY_ROLE() view returns (bytes32)",
  ];
  const usdc = new ethers.Contract(USDC, erc20, p);
  const tgb5 = new ethers.Contract(TGB5, erc20, p);
  const treasAbi = [
    "function feeSettlementAsset() view returns (address)",
    "function authorizedBridgeAsset(address) view returns (bool)",
    "function owner() view returns (address)",
    "function miners() view returns (address[])",
    "function requiredVotes() view returns (uint256)",
    "function destinationFeeBps(uint256) view returns (uint256)",
    "function assetPolicy(bytes32) view returns (tuple(uint256 sourceChainId,address sourceTreasury,address sourceAsset,address destinationAsset,uint8 mode,uint8 decimals,bool enabled,uint256 version))",
  ];
  const treas = new ethers.Contract(TREAS, treasAbi, p);

  const uBal = await usdc.balanceOf(USER);
  const tBal = await tgb5.balanceOf(USER);
  console.log({
    userUsdc: ethers.formatUnits(uBal, 6),
    userUsdcRaw: uBal.toString(),
    userTgb5: ethers.formatUnits(tBal, 18),
    feeSettlementAsset: await treas.feeSettlementAsset(),
    authUdc: await treas.authorizedBridgeAsset(USDC),
    authTgb5: await treas.authorizedBridgeAsset(TGB5),
    owner: await treas.owner(),
    miners: await treas.miners(),
    reqVotes: (await treas.requiredVotes()).toString(),
    feeBps224422: (await treas.destinationFeeBps(224422n)).toString(),
    userCnet: ethers.formatEther(await p.getBalance(USER)),
    treasuryUsdc: ethers.formatUnits(await usdc.balanceOf(TREAS), 6),
    usdcDec: await usdc.decimals(),
    tgb5Dec: await tgb5.decimals(),
    usdcSym: await usdc.symbol(),
    tgb5Sym: await tgb5.symbol(),
  });

  try {
    const br = await usdc.BRIDGE_ROLE();
    const tr = await usdc.TREASURY_ROLE();
    console.log("usdc bridgeRole treasury?", await usdc.hasRole(br, TREAS));
    console.log("usdc treasuryRole treasury?", await usdc.hasRole(tr, TREAS));
  } catch (e: any) {
    console.log("usdc role check fail", e.shortMessage || e.message);
  }
  try {
    const br = await tgb5.BRIDGE_ROLE();
    const tr = await tgb5.TREASURY_ROLE();
    console.log("tgb5 bridgeRole treasury?", await tgb5.hasRole(br, TREAS));
    console.log("tgb5 treasuryRole treasury?", await tgb5.hasRole(tr, TREAS));
  } catch (e: any) {
    console.log("tgb5 role check fail", e.shortMessage || e.message);
  }

  // policyId = keccak256(sourceChainId, sourceTreasury, sourceAsset, destinationAsset, mode)
  for (const mode of [0, 1, 2]) {
    const id = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "address", "address", "address", "uint8"],
        [224422n, TREAS, USDC, TGB5, mode],
      ),
    );
    const onchain = await treas.assetPolicy(id);
    console.log(`policy mode=${mode}`, {
      id,
      enabled: onchain.enabled,
      version: onchain.version.toString(),
      sourceAsset: onchain.sourceAsset,
      dest: onchain.destinationAsset,
      decimals: Number(onchain.decimals),
      mode: Number(onchain.mode),
    });
  }

  // also reverse TGB5 -> USDC
  for (const mode of [0, 1, 2]) {
    const id = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "address", "address", "address", "uint8"],
        [224422n, TREAS, TGB5, USDC, mode],
      ),
    );
    const onchain = await treas.assetPolicy(id);
    if (onchain.enabled || onchain.version > 0n) {
      console.log(`reverse policy mode=${mode}`, onchain);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
