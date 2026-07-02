/** One-off: add ConetTreasuryPeer as admin on B-Unit UUPS proxy. */
import { network } from "hardhat";
import { BUINT_UUPS_PROXY_PREDICTED } from "./erc20UupsDeployConstants.js";
import { CONET_TREASURY_PEER_CREATE2_PREDICTED } from "./conetTreasuryDeployConstants.js";

async function main() {
  const { ethers } = await network.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("no signer");
  const buintAddr = process.env.BUINT_ADDRESS?.trim() || BUINT_UUPS_PROXY_PREDICTED;
  const peerAddr = process.env.CONET_TREASURY_PEER?.trim() || CONET_TREASURY_PEER_CREATE2_PREDICTED;
  const buint = await ethers.getContractAt(
    ["function addAdmin(address)", "function admins(address) view returns (bool)"],
    buintAddr,
    signer
  );
  if (await buint.admins(peerAddr)) {
    console.log("Peer already admin on", buintAddr);
    return;
  }
  const tx = await buint.addAdmin(peerAddr);
  await tx.wait();
  console.log("addAdmin(Peer) ok:", tx.hash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
