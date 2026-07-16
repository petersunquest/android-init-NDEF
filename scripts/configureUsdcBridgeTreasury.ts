import { network as networkModule } from "hardhat";
import { getAddress } from "ethers";
import {
  BASE_USDC,
  CONET_USDC,
  CONET_TREASURY_MINER_REGISTRY,
} from "./usdcBridgeDeployConstants.js";

const ABI = [
  "function configure(address minerRegistry,address baseUsdc,address conetUsdc,address wcnet,uint256 quorum) external",
  "function requiredSignatures() view returns (uint256)",
  "function minerRegistry() view returns (address)",
  "function baseUsdc() view returns (address)",
  "function conetUsdc() view returns (address)",
  "function wcnet() view returns (address)",
];

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("No configuration signer");
  const bridgeAddress = getAddress(process.env.USDC_BRIDGE_TREASURY || "");
  if (!bridgeAddress) throw new Error("USDC_BRIDGE_TREASURY is required");

  const registry = getAddress(process.env.MINER_REGISTRY || CONET_TREASURY_MINER_REGISTRY);
  const baseUsdc = getAddress(process.env.BASE_USDC || BASE_USDC);
  const conetUsdc = getAddress(process.env.CONET_USDC || CONET_USDC);
  const wcnet = getAddress(process.env.WCNET || "0x0000000000000000000000000000000000000001");
  const conetTreasuryTokenRegistry = getAddress(
    process.env.CONET_TREASURY_TOKEN_REGISTRY || CONET_TREASURY_MINER_REGISTRY
  );
  const quorum = BigInt(process.env.BRIDGE_QUORUM || "0");
  const bridge = new ethers.Contract(bridgeAddress, ABI, signer);

  console.log("Configuring USDC/Native Bridge Treasury");
  console.log({ chainId: (await ethers.provider.getNetwork()).chainId.toString(), bridgeAddress, registry, conetTreasuryTokenRegistry, baseUsdc, conetUsdc, wcnet, quorum: quorum.toString() });
  const tx = await bridge.configure(registry, baseUsdc, conetUsdc, wcnet, quorum);
  console.log("configure tx:", tx.hash);
  await tx.wait();
  console.log("required signatures:", (await bridge.requiredSignatures()).toString());
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

