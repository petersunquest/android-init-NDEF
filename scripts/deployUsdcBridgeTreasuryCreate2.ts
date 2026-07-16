import { network as networkModule } from "hardhat";
import { getAddress } from "ethers";
import {
  NICK_CREATE2_FACTORY,
  USDC_BRIDGE_IMPL_CREATE2_SALT,
  USDC_BRIDGE_PROXY_CREATE2_SALT,
  USDC_BRIDGE_INITIAL_OWNER,
  CONET_TREASURY_MINER_REGISTRY,
} from "./usdcBridgeDeployConstants.js";
import {
  nickCreate2DeployCalldata,
  predictCreate2,
  predictUsdcBridgeUupsStack,
} from "./utils/usdcBridgeCreate2.js";

type Deployer = {
  address: string;
  estimateGas: (tx: object) => Promise<bigint>;
  sendTransaction: (tx: object) => Promise<{
    hash: string;
    wait: () => Promise<unknown>;
  }>;
};

async function deployNick(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  deployer: Deployer,
  factoryAddress: string,
  salt: string,
  initCode: string,
  label: string
): Promise<void> {
  const predicted = predictCreate2(factoryAddress, salt, initCode);
  const currentCode = await ethers.provider.getCode(predicted);
  if (currentCode !== "0x" && currentCode.length > 2) {
    console.log(`✅ ${label} already deployed: ${predicted}`);
    return;
  }
  const data = nickCreate2DeployCalldata(salt, initCode);
  let gasLimit = 8_000_000n;
  try {
    gasLimit = ((await deployer.estimateGas({ to: factoryAddress, data })) * 120n) / 100n;
  } catch {
    console.warn(`${label}: estimateGas failed; using default gas limit`);
  }
  const fee = await ethers.provider.getFeeData();
  const tx = await deployer.sendTransaction({
    to: factoryAddress,
    data,
    gasLimit,
    maxFeePerGas: ((fee.maxFeePerGas ?? 1_000_000_000n) * 3n),
    maxPriorityFeePerGas: ((fee.maxPriorityFeePerGas ?? 100_000_000n) * 3n),
  });
  console.log(`${label} deployment tx: ${tx.hash}`);
  await tx.wait();
  const deployedCode = await ethers.provider.getCode(predicted);
  if (deployedCode === "0x" || deployedCode.length <= 2) {
    throw new Error(`${label} has no code after CREATE2: ${predicted}`);
  }
  console.log(`✅ ${label}: ${predicted}`);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("No deployer signer");

  const factoryAddress = getAddress(process.env.ERC20_UUPS_FACTORY || NICK_CREATE2_FACTORY);
  const stack = await predictUsdcBridgeUupsStack({
    ethers,
    nickFactory: factoryAddress,
    implSalt: USDC_BRIDGE_IMPL_CREATE2_SALT,
    proxySalt: USDC_BRIDGE_PROXY_CREATE2_SALT,
    initialOwner: USDC_BRIDGE_INITIAL_OWNER,
    conetTreasuryTokenRegistry: CONET_TREASURY_MINER_REGISTRY,
  });
  const chainId = (await ethers.provider.getNetwork()).chainId.toString();

  console.log("USDC Bridge Treasury CREATE2 deployment");
  console.log("chainId:", chainId);
  console.log("implementation:", stack.impl);
  console.log("proxy:", stack.proxy);
  if (process.env.DRY_RUN === "1") return;

  const factoryCode = await ethers.provider.getCode(factoryAddress);
  if (factoryCode === "0x" || factoryCode.length <= 2) {
    throw new Error(`Nick CREATE2 factory has no code: ${factoryAddress}`);
  }
  await deployNick(
    ethers,
    signer as unknown as Deployer,
    factoryAddress,
    USDC_BRIDGE_IMPL_CREATE2_SALT,
    stack.implInitCode,
    "USDC Bridge implementation"
  );
  await deployNick(
    ethers,
    signer as unknown as Deployer,
    factoryAddress,
    USDC_BRIDGE_PROXY_CREATE2_SALT,
    stack.proxyInitCode,
    "USDC Bridge proxy"
  );

  const fs = await import("fs");
  const path = await import("path");
  const output = {
    chainId,
    deployer: signer.address,
    nickCreate2Factory: factoryAddress,
    implementation: stack.impl,
    proxy: stack.proxy,
    initialOwner: USDC_BRIDGE_INITIAL_OWNER,
    conetTreasuryTokenRegistry: CONET_TREASURY_MINER_REGISTRY,
    implSalt: USDC_BRIDGE_IMPL_CREATE2_SALT,
    proxySalt: USDC_BRIDGE_PROXY_CREATE2_SALT,
    sameAddressAcrossChains: true,
    deployedAt: new Date().toISOString(),
  };
  const file = path.join(process.cwd(), "deployments", `usdc-bridge-treasury-${chainId}.json`);
  fs.writeFileSync(file, JSON.stringify(output, null, 2) + "\n");
  console.log("wrote", file);
  console.log("Next: configure with scripts/configureUsdcBridgeTreasury.ts");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

