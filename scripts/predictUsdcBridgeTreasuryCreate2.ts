import { network as networkModule } from "hardhat";
import { getAddress } from "ethers";
import {
  NICK_CREATE2_FACTORY,
  USDC_BRIDGE_IMPL_CREATE2_SALT,
  USDC_BRIDGE_PROXY_CREATE2_SALT,
  USDC_BRIDGE_INITIAL_OWNER,
  CONET_TREASURY_MINER_REGISTRY,
} from "./usdcBridgeDeployConstants.js";
import { predictUsdcBridgeUupsStack } from "./utils/usdcBridgeCreate2.js";

async function main() {
  const { ethers } = await networkModule.connect();
  const stack = await predictUsdcBridgeUupsStack({
    ethers,
    nickFactory: getAddress(NICK_CREATE2_FACTORY),
    implSalt: USDC_BRIDGE_IMPL_CREATE2_SALT,
    proxySalt: USDC_BRIDGE_PROXY_CREATE2_SALT,
    initialOwner: USDC_BRIDGE_INITIAL_OWNER,
    conetTreasuryTokenRegistry: CONET_TREASURY_MINER_REGISTRY,
  });
  console.log("USDC Bridge Treasury UUPS CREATE2 prediction:");
  console.log("  implementation:", stack.impl);
  console.log("  proxy:", stack.proxy);
  console.log("  owner:", USDC_BRIDGE_INITIAL_OWNER);
  console.log("  same proxy init code must be used on Base and CoNET");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

