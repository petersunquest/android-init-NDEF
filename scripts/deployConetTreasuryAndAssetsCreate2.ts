/**
 * Canonical treasury + bridge assets deployment on CoNET or Base.
 *
 * Deploys, on CoNET 224422 or Base 8453:
 *   1. ConetTreasury via Nick CREATE2
 *   2. wCNET FactoryERC20Upgradeable UUPS implementation + proxy
 *   3. CONET-USDC FactoryERC20Upgradeable UUPS implementation + proxy
 *
 * The ERC20 initializer minter is the predicted Treasury address, so the
 * token addresses remain deterministic and identical when this script is
 * run on both chains with the same compiled bytecode.
 *
 * Preview only:
 *   DRY_RUN=1 npx hardhat run scripts/deployConetTreasuryAndAssetsCreate2.ts --network conet
 */
import { network as networkModule } from "hardhat";
import { concat, getAddress, Interface, keccak256, solidityPacked } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  CONET_TREASURY_CREATE2_SALT,
  CONET_TREASURY_INITIAL_MINER,
  NICK_CREATE2_FACTORY,
} from "./conetTreasuryDeployConstants.js";
import {
  BUINT_IMPL_CREATE2_SALT,
  BUINT_PROXY_CREATE2_SALT,
  BUINT_INITIAL_ADMIN,
  CONET_USDC_IMPL_CREATE2_SALT,
  CONET_USDC_PROXY_CREATE2_SALT,
  CONET_USDC_TOKEN_DECIMALS,
  CONET_USDC_TOKEN_NAME,
  CONET_USDC_TOKEN_SYMBOL,
  WCNET_IMPL_CREATE2_SALT,
  WCNET_PROXY_CREATE2_SALT,
  WCNET_TOKEN_DECIMALS,
  WCNET_TOKEN_NAME,
  WCNET_TOKEN_SYMBOL,
  GBTOKEN_IMPL_CREATE2_SALT,
  GBTOKEN_PROXY_CREATE2_SALT,
  GBTOKEN_INITIAL_ADMIN,
} from "./erc20UupsDeployConstants.js";
import { predictErc20UupsStack } from "./utils/erc20UupsCreate2.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function predictCreate2(factory: string, salt: string, initCode: string): string {
  return getAddress(
    "0x" +
      keccak256(
        solidityPacked(
          ["bytes1", "address", "bytes32", "bytes32"],
          ["0xff", getAddress(factory), salt, keccak256(initCode)]
        )
      ).slice(-40)
  );
}

async function deployNick(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  signer: { sendTransaction: (tx: object) => Promise<{ hash: string; wait: () => Promise<unknown> }>; estimateGas: (tx: object) => Promise<bigint> },
  factory: string,
  salt: string,
  initCode: string,
  label: string,
  dryRun: boolean
): Promise<{ address: string; deployed: boolean }> {
  const address = predictCreate2(factory, salt, initCode);
  const existing = await ethers.provider.getCode(address);
  if (existing !== "0x" && existing.length > 2) {
    console.log(`✅ ${label} already deployed:`, address);
    return { address, deployed: false };
  }
  if (dryRun) {
    console.log(`DRY_RUN ${label}:`, address);
    return { address, deployed: false };
  }
  const data = concat([salt, initCode]);
  const gasLimit = ((await signer.estimateGas({ to: factory, data })) * 120n) / 100n;
  const tx = await signer.sendTransaction({ to: factory, data, gasLimit });
  console.log(`${label} deploy tx:`, tx.hash);
  await tx.wait();
  const code = await ethers.provider.getCode(address);
  if (code === "0x" || code.length <= 2) throw new Error(`${label} deployment produced no code`);
  return { address, deployed: true };
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 224422n && network.chainId !== 8453n) {
    throw new Error(`Expected CoNET 224422 or Base 8453, got ${network.chainId}`);
  }

  const factory = getAddress(process.env.CONET_TREASURY_CREATE2_FACTORY || NICK_CREATE2_FACTORY);
  const dryRun = process.env.DRY_RUN === "1";
  const treasuryFactory = await ethers.getContractFactory("ConetTreasury");
  const treasuryDeployTx = await treasuryFactory.getDeployTransaction(CONET_TREASURY_INITIAL_MINER);
  if (!treasuryDeployTx.data) throw new Error("Unable to build ConetTreasury init code");
  const treasuryAddress = predictCreate2(factory, CONET_TREASURY_CREATE2_SALT, treasuryDeployTx.data);

  console.log("CoNET treasury:", treasuryAddress);
  console.log("wCNET / CONET-USDC minter:", treasuryAddress);
  console.log("Nick factory:", factory);

  const treasuryDeployment = await deployNick(
    ethers,
    deployer,
    factory,
    CONET_TREASURY_CREATE2_SALT,
    treasuryDeployTx.data,
    "ConetTreasury",
    dryRun
  );

  const usdc = await predictErc20UupsStack({
    ethers,
    nickFactory: factory,
    implSalt: CONET_USDC_IMPL_CREATE2_SALT,
    proxySalt: CONET_USDC_PROXY_CREATE2_SALT,
    contractName: "FactoryERC20Upgradeable",
    encodeInitialize: (iface: Interface) =>
      iface.encodeFunctionData("initialize", [
        CONET_USDC_TOKEN_NAME,
        CONET_USDC_TOKEN_SYMBOL,
        CONET_USDC_TOKEN_DECIMALS,
        treasuryAddress,
      ]),
  });
  const buint = await predictErc20UupsStack({
    ethers,
    nickFactory: factory,
    implSalt: BUINT_IMPL_CREATE2_SALT,
    proxySalt: BUINT_PROXY_CREATE2_SALT,
    contractName: "BeamioBUnits",
    encodeInitialize: (iface: Interface) =>
      iface.encodeFunctionData("initialize", [BUINT_INITIAL_ADMIN]),
  });
  const gb = await predictErc20UupsStack({
    ethers,
    nickFactory: factory,
    implSalt: GBTOKEN_IMPL_CREATE2_SALT,
    proxySalt: GBTOKEN_PROXY_CREATE2_SALT,
    contractName: "GBToken",
    encodeInitialize: (iface: Interface) =>
      iface.encodeFunctionData("initialize", [GBTOKEN_INITIAL_ADMIN]),
  });
  const wcnet = await predictErc20UupsStack({
    ethers,
    nickFactory: factory,
    implSalt: WCNET_IMPL_CREATE2_SALT,
    proxySalt: WCNET_PROXY_CREATE2_SALT,
    contractName: "FactoryERC20Upgradeable",
    encodeInitialize: (iface: Interface) =>
      iface.encodeFunctionData("initialize", [
        WCNET_TOKEN_NAME,
        WCNET_TOKEN_SYMBOL,
        WCNET_TOKEN_DECIMALS,
        treasuryAddress,
      ]),
  });
  const usdcImpl = await deployNick(ethers, deployer, factory, CONET_USDC_IMPL_CREATE2_SALT, usdc.implInitCode, "CONET-USDC implementation", dryRun);
  const usdcProxy = await deployNick(ethers, deployer, factory, CONET_USDC_PROXY_CREATE2_SALT, usdc.proxyInitCode, "CONET-USDC proxy", dryRun);
  const wcnetImpl = await deployNick(ethers, deployer, factory, WCNET_IMPL_CREATE2_SALT, wcnet.implInitCode, "wCNET implementation", dryRun);
  const wcnetProxy = await deployNick(ethers, deployer, factory, WCNET_PROXY_CREATE2_SALT, wcnet.proxyInitCode, "wCNET proxy", dryRun);
  const buintImpl = await deployNick(ethers, deployer, factory, BUINT_IMPL_CREATE2_SALT, buint.implInitCode, "B-Unit implementation", dryRun);
  const buintProxy = await deployNick(ethers, deployer, factory, BUINT_PROXY_CREATE2_SALT, buint.proxyInitCode, "B-Unit proxy", dryRun);
  const gbImpl = await deployNick(ethers, deployer, factory, GBTOKEN_IMPL_CREATE2_SALT, gb.implInitCode, "GB implementation", dryRun);
  const gbProxy = await deployNick(ethers, deployer, factory, GBTOKEN_PROXY_CREATE2_SALT, gb.proxyInitCode, "GB proxy", dryRun);

  const out = {
    network: network.chainId === 224422n ? "conet" : "base",
    chainId: network.chainId.toString(),
    treasury: treasuryAddress,
    conetUsdc: usdcProxy.address,
    conetUsdcImplementation: usdcImpl.address,
    wcnet: wcnetProxy.address,
    wcnetImplementation: wcnetImpl.address,
    buint: buintProxy.address,
    buintImplementation: buintImpl.address,
    gb: gbProxy.address,
    gbImplementation: gbImpl.address,
    minter: treasuryAddress,
    sameAddressDeployment: true,
    dryRun,
    deployer: process.env.DEPLOYER_ADDRESS || "runtime-signer",
    updatedAt: new Date().toISOString(),
  };
  const outPath = path.join(
    __dirname,
    "..",
    "deployments",
    network.chainId === 224422n
      ? "conet-treasury-bridge-assets.json"
      : "base-treasury-bridge-assets.json"
  );
  if (!dryRun) {
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf8");
    console.log("Saved:", outPath);
  } else {
    console.log("DRY_RUN output (not written):", JSON.stringify(out, null, 2));
  }
  console.log("Icons are registered separately through Blockscout icon_url:");
  console.log("  wCNET  https://mainnet.conet.network/wcnet/erc20/wCNET-256.png");
  console.log("  USDC   https://mainnet.conet.network/usdc/erc20/USDC-256.png");
  if (network.chainId === 8453n) {
    console.log("BaseScan Token Info must be submitted separately for GB, B-Unit and wCNET.");
    console.log("The uploaded 256px PNG files are the logo inputs; BaseScan does not read icon from ERC20 bytecode.");
  }
  void treasuryDeployment;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
