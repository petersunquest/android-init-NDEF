/** Set ConetTreasuryPeer.gbTokenErc20 to GB UUPS proxy. */
import { network } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { GBTOKEN_UUPS_PROXY_PREDICTED } from "./erc20UupsDeployConstants.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function resolvePeerAddress(): string {
  if (process.env.CONET_TREASURY_PEER?.trim()) return process.env.CONET_TREASURY_PEER.trim();
  const addrJson = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  if (fs.existsSync(addrJson)) {
    const j = JSON.parse(fs.readFileSync(addrJson, "utf-8")) as { ConetTreasuryPeer?: string };
    if (j.ConetTreasuryPeer) return j.ConetTreasuryPeer;
  }
  const meta = path.join(__dirname, "..", "deployments", "conetTreasuryPeer-create2-meta.json");
  if (fs.existsSync(meta)) {
    return JSON.parse(fs.readFileSync(meta, "utf-8")).predictedAddress as string;
  }
  throw new Error("missing ConetTreasuryPeer (set CONET_TREASURY_PEER or conet-addresses.json)");
}

async function main() {
  const { ethers } = await network.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("no signer");
  const gbAddr = process.env.GB_TOKEN_ADDRESS?.trim() || GBTOKEN_UUPS_PROXY_PREDICTED;
  const peerAddr = resolvePeerAddress();
  const peer = await ethers.getContractAt(
    ["function gbTokenErc20() view returns (address)", "function setGbTokenErc20(address)"],
    peerAddr,
    signer
  );
  const current = await peer.gbTokenErc20();
  if (current.toLowerCase() === gbAddr.toLowerCase()) {
    console.log("Peer.gbTokenErc20 already", gbAddr);
    return;
  }
  const tx = await peer.setGbTokenErc20(gbAddr);
  await tx.wait();
  console.log("setGbTokenErc20 ok:", gbAddr, tx.hash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
