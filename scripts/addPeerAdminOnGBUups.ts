/** Add ConetTreasuryPeer as admin on GBToken UUPS proxy. */
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
  throw new Error("missing ConetTreasuryPeer");
}

async function main() {
  const { ethers } = await network.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("no signer");
  const gbAddr = process.env.GB_TOKEN_ADDRESS?.trim() || GBTOKEN_UUPS_PROXY_PREDICTED;
  const peerAddr = resolvePeerAddress();
  const gb = await ethers.getContractAt(
    ["function addAdmin(address)", "function admins(address) view returns (bool)"],
    gbAddr,
    signer
  );
  if (await gb.admins(peerAddr)) {
    console.log("Peer already admin on", gbAddr);
    return;
  }
  const tx = await gb.addAdmin(peerAddr);
  await tx.wait();
  console.log("addAdmin(Peer) ok:", tx.hash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
