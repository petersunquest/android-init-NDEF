/**
 * Deploy the four canonical Treasury V3 ERC20 proxies. The implementation
 * and proxy salts are asset-specific, while init calldata is identical on
 * Base and CoNET when the bridge proxy/owner are identical.
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import {
  deployViaNick,
  initCodeFor,
  NICK_CREATE2_FACTORY,
  saltFromLabel,
} from "./utils/treasuryV3Create2.js";
import { loadSignerPk } from "./utils/loadSignerPk.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const DEPLOYMENTS = path.join(ROOT, "deployments");

const ASSETS = [
  { key: "wCNET", name: "Wrapped CoNET", symbol: "wCNET", decimals: 18, slug: "wcnet" },
  { key: "conetUSDC", name: "CoNET USD Coin", symbol: "conet-USDC", decimals: 6, slug: "usdc" },
  { key: "GB", name: "CONET GB", symbol: "GB", decimals: 9, slug: "gb" },
  { key: "BUnit", name: "Beamio Units", symbol: "B-UNITS", decimals: 6, slug: "bunit" },
] as const;

function readBridgeAddress(chainId: number): string {
  const file = path.join(DEPLOYMENTS, `${chainId === 8453 ? "base" : "conet"}-treasury-v3.json`);
  if (!fs.existsSync(file)) throw new Error(`Deploy Treasury V3 first: ${file}`);
  const data = JSON.parse(fs.readFileSync(file, "utf8"));
  return data.contracts.TreasuryBridgeV3Proxy;
}

async function main() {
  const { ethers } = await networkModule.connect();
  const configuredSigners = await ethers.getSigners();
  const deployer = configuredSigners[0] ?? new ethers.Wallet(loadSignerPk(), ethers.provider);
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  if (chainId !== 8453 && chainId !== 224422) throw new Error("Use --network base or --network conet");
  if ((await ethers.provider.getCode(NICK_CREATE2_FACTORY)) === "0x") {
    throw new Error(`Nick CREATE2 factory is not deployed on chain ${chainId}`);
  }
  const bridge = process.env.TREASURY_V3_BRIDGE ?? readBridgeAddress(chainId);
  const admin = process.env.TREASURY_V3_ASSET_ADMIN ?? deployer.address;
  const requestedAssetKey = process.env.TREASURY_V3_ASSET_KEY?.trim();
  const assets = requestedAssetKey
    ? ASSETS.filter((asset) => asset.key.toLowerCase() === requestedAssetKey.toLowerCase())
    : ASSETS;
  if (assets.length === 0) {
    throw new Error(`Unknown TREASURY_V3_ASSET_KEY=${requestedAssetKey}`);
  }
  const tokenFactory = await ethers.getContractFactory("TreasuryCanonicalERC20V3");
  const output: Record<string, unknown> = {
    network: chainId === 8453 ? "base" : "conet",
    chainId,
    bridge,
    admin,
    nickCreate2Factory: NICK_CREATE2_FACTORY,
    assets: {},
    createdAt: new Date().toISOString(),
  };

  for (const asset of assets) {
    const implementation = await deployViaNick(
      deployer,
      await initCodeFor(tokenFactory),
      saltFromLabel(ethers, `${asset.slug}-implementation`),
      ethers.provider,
    );
    const metadata = process.env[`TREASURY_V3_${asset.key.toUpperCase()}_METADATA`] ??
      `https://mainnet.conet.network/${asset.slug}/erc20/metadata.json`;
    const initData = tokenFactory.interface.encodeFunctionData("initialize", [
      asset.name,
      asset.symbol,
      asset.decimals,
      admin,
      bridge,
      metadata,
    ]);
    const proxyFactory = await ethers.getContractFactory("TreasuryV3ERC1967Proxy");
    const proxyInitCode = await initCodeFor(proxyFactory, implementation.address, initData);
    const proxy = await deployViaNick(
      deployer,
      proxyInitCode,
      saltFromLabel(ethers, `${asset.slug}-proxy`),
      ethers.provider,
    );
    (output.assets as Record<string, unknown>)[asset.key] = {
      name: asset.name,
      symbol: asset.symbol,
      decimals: asset.decimals,
      metadata,
      implementation: implementation.address,
      proxy: proxy.address,
      implementationTx: implementation.txHash ?? null,
      proxyTx: proxy.txHash ?? null,
      reused: implementation.reused || proxy.reused,
    };
    console.log(`${asset.symbol}: ${proxy.address}`);
  }

  fs.mkdirSync(DEPLOYMENTS, { recursive: true });
  const outputPath = path.join(
    DEPLOYMENTS,
    `${chainId === 8453 ? "base" : "conet"}-treasury-v3-assets.json`,
  );
  if (fs.existsSync(outputPath)) {
    const previous = JSON.parse(fs.readFileSync(outputPath, "utf8")) as {
      assets?: Record<string, unknown>;
    };
    output.assets = {
      ...(previous.assets ?? {}),
      ...(output.assets as Record<string, unknown>),
    };
  }
  fs.writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`);
  console.log(`Saved ${outputPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
