/**
 * Set BeamioUserCardFactoryPaymasterV07.aaFactory using the first configured Hardhat signer.
 *
 * Useful on CoNET where hardhat.config.ts loads the owner/admin keys from ~/.master.json.
 *
 * Usage:
 *   npx hardhat run scripts/setCardFactoryAAFactoryWithSigner.ts --network conet
 *   NEW_AA_FACTORY=0x... npx hardhat run scripts/setCardFactoryAAFactoryWithSigner.ts --network conet
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { getAddress } from "ethers";
import { BEAMIO_AA_FACTORY_PREDICTED } from "./aaDeployConstants.js";
import { resolveBaseCardFactoryAddress } from "./readCanonicalBaseCardFactory.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const BASE_CHAIN_ID = 8453n;
const CONET_CHAIN_ID = 224422n;

function readJson(pathname: string): Record<string, any> {
  if (!fs.existsSync(pathname)) return {};
  return JSON.parse(fs.readFileSync(pathname, "utf-8"));
}

function resolveCardFactory(chainId: bigint): string {
  if (process.env.CARD_FACTORY) return getAddress(process.env.CARD_FACTORY);
  if (chainId === CONET_CHAIN_ID) {
    const conet = readJson(path.join(ROOT, "deployments", "conet-addresses.json"));
    return getAddress(String(conet.CARD_FACTORY));
  }
  if (chainId === BASE_CHAIN_ID) {
    return resolveBaseCardFactoryAddress(path.join(ROOT, "deployments"));
  }
  throw new Error(`Unsupported chainId ${chainId.toString()}; set CARD_FACTORY`);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("No configured signer");

  const net = await ethers.provider.getNetwork();
  const cardFactoryAddress = resolveCardFactory(net.chainId);
  const newAAFactory = getAddress(process.env.NEW_AA_FACTORY || BEAMIO_AA_FACTORY_PREDICTED);
  const abi = [
    "function owner() external view returns (address)",
    "function aaFactory() external view returns (address)",
    "function setAAFactory(address f) external",
  ];
  const cardFactory = new ethers.Contract(cardFactoryAddress, abi, signer);
  const owner = getAddress(await cardFactory.owner());
  const signerAddress = getAddress(await signer.getAddress());
  console.log("chainId:", net.chainId.toString());
  console.log("cardFactory:", cardFactoryAddress);
  console.log("owner:", owner);
  console.log("signer:", signerAddress);
  console.log("target aaFactory:", newAAFactory);
  if (owner.toLowerCase() !== signerAddress.toLowerCase()) {
    throw new Error("Configured signer is not Card Factory owner");
  }
  const current = getAddress(await cardFactory.aaFactory());
  if (current.toLowerCase() === newAAFactory.toLowerCase()) {
    console.log("Card Factory aaFactory already target");
    return;
  }
  console.log("current aaFactory:", current);
  const tx = await cardFactory.setAAFactory(newAAFactory);
  console.log("tx:", tx.hash);
  await tx.wait();
  console.log("done");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
