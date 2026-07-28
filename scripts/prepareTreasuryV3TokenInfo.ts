/**
 * Generate the off-chain BaseScan Token Info manifest after Base deployment.
 * Logos are uploaded separately; BaseScan does not read icon URLs from ERC20
 * bytecode or contractURI.
 */
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const deployments = JSON.parse(
  fs.readFileSync(path.join(ROOT, "deployments/base-treasury-v3-assets.json"), "utf8"),
);
const iconUrlFor = (asset: any): string => {
  const slug =
    asset.symbol === "wCNET"
      ? "wcnet"
      : asset.symbol === "conet-USDC"
        ? "usdc"
        : asset.symbol.toLowerCase() === "gb"
          ? "gb"
          : "bunit";
  const metadataPath = path.join(ROOT, "deployments/assets", slug, "erc20/metadata.json");
  if (fs.existsSync(metadataPath)) {
    const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
    if (typeof metadata.image === "string" && metadata.image.length > 0) return metadata.image;
  }
  return asset.metadata;
};
const tokenInfo = Object.values(deployments.assets).map((asset: any) => ({
  address: asset.proxy,
  name: asset.name,
  symbol: asset.symbol,
  decimals: asset.decimals,
  iconUrl: iconUrlFor(asset),
  explorer: `https://basescan.org/token/${asset.proxy}`,
}));
const outputPath = path.join(ROOT, "deployments/assets/base/token-info.json");
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(
  outputPath,
  `${JSON.stringify({ chain: "Base", chainId: 8453, tokens: tokenInfo }, null, 2)}\n`,
);
console.log(`Saved ${outputPath}`);
