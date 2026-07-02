/**
 * 预测跨链同址 CREATE2 地址（Nick factory + 固定 salt/initCode）。
 * 运行: npx hardhat run scripts/predictCrossChainAssets.ts
 */

import { network as networkModule } from "hardhat";
import { id, getAddress, keccak256, solidityPacked } from "ethers";
import {
  BUINT_CREATE2_SALT,
  BUINT_INITIAL_ADMIN,
  NICK_CREATE2_FACTORY,
} from "./bunitDeployConstants.js";
import {
  GB_CREATE2_SALT,
  GB_INITIAL_ADMIN,
  GB_START_HOUR_ID,
  GB_START_TIME,
  GB_TOTAL_CREATE2_SALT,
  GB_USER_TOTAL_CREATE2_SALT,
} from "./gbDeployConstants.js";
import {
  BASE_MAINNET_CHAIN_ID,
  BUINT_PEER_TOKEN,
  CONET_CHAIN_ID,
  CONET_TREASURY_CREATE2_SALT,
  CONET_TREASURY_INITIAL_MINER,
  CONET_TREASURY_PEER_CREATE2_SALT,
  CONET_TREASURY_PEER_WRAPPED_LIB_CREATE2_SALT,
  CONET_TREASURY_PEER_STABLE_SWAP_LIB_CREATE2_SALT,
  GB_PEER_TOKEN,
  NATIVE_PEER_TOKEN,
  WRAPPED_ERC20_SALT_PREFIX,
} from "./conetTreasuryDeployConstants.js";
import {
  BEAMIO_AA_FACTORY_ADMIN,
  BEAMIO_AA_FACTORY_CREATE2_SALT,
  BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT,
} from "./aaDeployConstants.js";

function predictCreate2(factory: string, salt: string, initCode: string): string {
  return getAddress(
    "0x" +
      keccak256(
        solidityPacked(
          ["bytes1", "address", "bytes32", "bytes32"],
          ["0xff", factory, salt, keccak256(initCode)]
        )
      ).slice(-40)
  );
}

async function main() {
  const { ethers } = await networkModule.connect();
  const nick = getAddress(NICK_CREATE2_FACTORY);

  const buintFactory = await ethers.getContractFactory("BeamioBUnits");
  const buintInit = (await buintFactory.getDeployTransaction(BUINT_INITIAL_ADMIN)).data!;
  const buint = predictCreate2(nick, BUINT_CREATE2_SALT, buintInit);

  const gbFactory = await ethers.getContractFactory("ConetGB1155");
  const gbInit = (
    await gbFactory.getDeployTransaction(GB_START_TIME, GB_START_HOUR_ID, GB_INITIAL_ADMIN)
  ).data!;
  const gb = predictCreate2(nick, GB_CREATE2_SALT, gbInit);

  const totalFactory = await ethers.getContractFactory("ConetGB_total");
  const totalInit = (await totalFactory.getDeployTransaction(gb)).data!;
  const gbTotal = predictCreate2(nick, GB_TOTAL_CREATE2_SALT, totalInit);

  const userTotalFactory = await ethers.getContractFactory("ConetGB_userTotal");
  const userTotalInit = (await userTotalFactory.getDeployTransaction(gb)).data!;
  const gbUserTotal = predictCreate2(nick, GB_USER_TOTAL_CREATE2_SALT, userTotalInit);

  const treasuryFactory = await ethers.getContractFactory("ConetTreasury");
  const treasuryInit = (
    await treasuryFactory.getDeployTransaction(CONET_TREASURY_INITIAL_MINER)
  ).data!;
  const treasury = predictCreate2(nick, CONET_TREASURY_CREATE2_SALT, treasuryInit);

  const wrappedLibFactory = await ethers.getContractFactory("ConetTreasuryPeerWrappedLib");
  const wrappedLibInit = (await wrappedLibFactory.getDeployTransaction()).data!;
  const wrappedLib = predictCreate2(nick, CONET_TREASURY_PEER_WRAPPED_LIB_CREATE2_SALT, wrappedLibInit);

  const stableSwapLibFactory = await ethers.getContractFactory("ConetTreasuryPeerStableSwapLib");
  const stableSwapLibInit = (await stableSwapLibFactory.getDeployTransaction()).data!;
  const stableSwapLib = predictCreate2(
    nick,
    CONET_TREASURY_PEER_STABLE_SWAP_LIB_CREATE2_SALT,
    stableSwapLibInit
  );

  const WRAPPED_LIB_FQN = "project/src/b-unit/ConetTreasuryPeerWrappedLib.sol:ConetTreasuryPeerWrappedLib";
  const STABLE_SWAP_LIB_FQN =
    "project/src/b-unit/ConetTreasuryPeerStableSwapLib.sol:ConetTreasuryPeerStableSwapLib";
  const peerFactory = await ethers.getContractFactory("ConetTreasuryPeer", {
    libraries: {
      [WRAPPED_LIB_FQN]: wrappedLib,
      [STABLE_SWAP_LIB_FQN]: stableSwapLib,
    },
  });
  const peerInit = (await peerFactory.getDeployTransaction(treasury)).data!;
  const peer = predictCreate2(nick, CONET_TREASURY_PEER_CREATE2_SALT, peerInit);

  const factoryErc20 = await ethers.getContractFactory("FactoryERC20");
  const wInit = (
    await factoryErc20.getDeployTransaction("Wrapped CoNET", "wCNET", 18, treasury)
  ).data!;
  const wSalt = keccak256(
    solidityPacked(
      ["string", "uint256", "address"],
      [WRAPPED_ERC20_SALT_PREFIX, CONET_CHAIN_ID, NATIVE_PEER_TOKEN]
    )
  );
  const wCnet = predictCreate2(nick, wSalt, wInit);

  const aaFactoryContract = await ethers.getContractFactory("BeamioFactoryPaymasterV07");
  const aaFactoryInit = (
    await aaFactoryContract.getDeployTransaction(
      BEAMIO_AA_FACTORY_INITIAL_ACCOUNT_LIMIT,
      BEAMIO_AA_FACTORY_ADMIN
    )
  ).data!;
  const aaFactory = predictCreate2(nick, BEAMIO_AA_FACTORY_CREATE2_SALT, aaFactoryInit);

  console.log("Cross-chain CREATE2 predicted addresses (all chains with Nick factory):");
  console.log("  BeamioFactoryPaymasterV07:", aaFactory);
  console.log("  ConetTreasury:    ", treasury);
  console.log("  ConetTreasuryPeerWrappedLib:", wrappedLib);
  console.log("  ConetTreasuryPeerStableSwapLib:", stableSwapLib);
  console.log("  ConetTreasuryPeer:", peer);
  console.log("  wCNET:            ", wCnet);
  console.log("  BeamioBUnits: ", buint);
  console.log("  ConetGB1155:  ", gb);
  console.log("  ConetGB_total:", gbTotal);
  console.log("  ConetGB_userTotal:", gbUserTotal);
  console.log("\nPeer bridge keys (voteMintFromPeerDeposit) — ERC20 canonical（推荐）:");
  console.log("  GB ERC20:   peerToken = GBToken 同址 (9 decimals)");
  console.log("  USDC:       peerToken = Base 0x833589… / CoNET conet-USDC 0x2975… (6 decimals)");
  console.log("  B-Unit:     peerToken = BeamioBUnits 同址 (6 decimals)");
  console.log("\nLegacy phantom keys（USE_ERC20_CANONICAL=0）:");
  console.log("  B-Units: peerToken=", BUINT_PEER_TOKEN);
  console.log("  GB 1155: peerToken=", GB_PEER_TOKEN, "(amount = amountGB18)");
  console.log("\nRelayer 目标链投票合约: ConetTreasuryPeer.voteMintFromPeerDeposit(...)");
  console.log("  voteMintFromPeerDeposit(burnTxHash, sourceChainId, BUINT_PEER_TOKEN, recipient, amount)");
  console.log("  voteMintFromPeerDeposit(burnTxHash, sourceChainId, GB_PEER_TOKEN, recipient, amountGB18)");
  console.log("\nDefault peer pairs (registerPeerBridgeAssets): CoNET", CONET_CHAIN_ID.toString(), "<-> Base", BASE_MAINNET_CHAIN_ID.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
