/**
 * Configure canonical assets and the initial route policies. Every write is
 * awaited before the next write, so one deployer cannot race its nonce.
 */
import { network as networkModule } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const DEPLOYMENTS = path.join(ROOT, "deployments");

function readJson(file: string): any {
  if (!fs.existsSync(file)) throw new Error(`Missing deployment file ${file}`);
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const prefix = chainId === 8453 ? "base" : "conet";
  const deployment = readJson(path.join(DEPLOYMENTS, `${prefix}-treasury-v3.json`));
  const assets = readJson(path.join(DEPLOYMENTS, `${prefix}-treasury-v3-assets.json`));
  const bridge = await ethers.getContractAt(
    "TreasuryBridgeV3",
    deployment.contracts.TreasuryBridgeV3Proxy,
    signer,
  );

  const feeBps = Number(process.env.TREASURY_V3_EXIT_FEE_BPS ?? "100");
  const destinationChainId = Number(
    process.env.TREASURY_V3_DESTINATION_CHAIN_ID ?? (chainId === 8453 ? "224422" : "8453"),
  );
  const feeTx = await bridge.setDestinationFeeBps(destinationChainId, feeBps);
  await feeTx.wait();
  console.log(`fee ${destinationChainId}=${feeBps} BPS`);

  const governanceEoas = (process.env.TREASURY_V3_GOVERNANCE_EOAS ?? "")
    .split(",")
    .map((address) => address.trim())
    .filter(Boolean);
  for (const governanceEoa of governanceEoas) {
    const tx = await bridge.setGovernanceEoa(governanceEoa, true);
    await tx.wait();
    console.log(`governance EOA enabled: ${governanceEoa}`);
  }

  if (chainId === 224422) {
    for (const asset of Object.values(assets.assets) as Array<{ proxy: string; symbol: string }>) {
      const tx = await bridge.setBridgeAssetAuthorization(asset.proxy, true);
      await tx.wait();
      console.log(`authorized ${asset.symbol}: ${asset.proxy}`);
    }
  }

  const output = {
    network: prefix,
    chainId,
    bridge: deployment.contracts.TreasuryBridgeV3Proxy,
    destinationChainId,
    feeBps,
    configuredBy: signer.address,
    configuredAt: new Date().toISOString(),
  };
  const outputPath = path.join(DEPLOYMENTS, `${prefix}-treasury-v3-config.json`);
  fs.writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`);
  console.log(`Saved ${outputPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
