import { getAddress, id } from "ethers";

export { NICK_CREATE2_FACTORY } from "./bunitDeployConstants.js";

/** Same initializer owner on both chains keeps CREATE2 proxy init code identical. */
export const USDC_BRIDGE_INITIAL_OWNER = getAddress(
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

export const USDC_BRIDGE_IMPL_CREATE2_SALT = id("beamio.usdc_bridge.impl.v1");
export const USDC_BRIDGE_PROXY_CREATE2_SALT = id("beamio.usdc_bridge.proxy.v1");

export const BASE_CHAIN_ID = 8453n;
export const CONET_CHAIN_ID = 224422n;
export const BASE_USDC = getAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
export const CONET_USDC = getAddress("0xfD0D7B0706AaB5E4351bcED37bC3C77ed6813907");
/** Filled by the wCNET CREATE2 prediction script after the bridge proxy is compiled. */
export const WCNET_SYMBOL = "wCNET";
export const WCNET_NAME = "Wrapped CoNET";
export const WCNET_DECIMALS = 18;
export const CONET_TREASURY_MINER_REGISTRY = getAddress(
  "0xa311c8fBE7CafC611603Ee925465A62493B73B30"
);

