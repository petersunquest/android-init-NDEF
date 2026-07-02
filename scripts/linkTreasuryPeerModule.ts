/** Point ConetTreasury.peerModule at deployed ConetTreasuryPeer (miner-only). */
import { network } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { CONET_TREASURY_CREATE2_PREDICTED } from "./conetTreasuryDeployConstants.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  const { ethers } = await network.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("no signer");

  const treasuryAddr = ethers.getAddress(
    process.env.CONET_TREASURY?.trim() ||
      JSON.parse(fs.readFileSync(path.join(__dirname, "..", "deployments", "conet-addresses.json"), "utf-8"))
        .ConetTreasury ||
      CONET_TREASURY_CREATE2_PREDICTED
  );
  const peerMeta = path.join(__dirname, "..", "deployments", "conetTreasuryPeer-create2-meta.json");
  const peerAddr = ethers.getAddress(
    process.env.CONET_TREASURY_PEER?.trim() ||
      (fs.existsSync(peerMeta)
        ? JSON.parse(fs.readFileSync(peerMeta, "utf-8")).predictedAddress
        : "")
  );
  if (!peerAddr) throw new Error("missing peer address");

  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddr, signer);
  const current = await treasury.peerModule();
  if (current.toLowerCase() === peerAddr.toLowerCase()) {
    console.log("peerModule already", peerAddr);
    return;
  }
  console.log("setPeerModule", peerAddr, "on Treasury", treasuryAddr, "(was", current, ")");
  const tx = await treasury.setPeerModule(peerAddr);
  await tx.wait();
  console.log("ok:", tx.hash, "→", await treasury.peerModule());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
