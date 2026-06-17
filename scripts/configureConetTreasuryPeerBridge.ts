/**
 * ConetTreasuryPeer 跨链桥 post-deploy（各链 CREATE2 同址 + setPeerModule 后执行）:
 *   Peer.setBUint / setConetGB
 *   BeamioBUnits.addAdmin(Peer)
 *   ConetGB1155.grantRole(ISSUER_ROLE, Peer)
 *
 * 环境变量:
 *   CONET_TREASURY / CONET_TREASURY_PEER — 覆盖地址
 *   BUINT_ADDRESS / GB_ADDRESS — CREATE2 同址
 *   SKIP_BUINT_ADMIN=1 / SKIP_GB_ISSUER=1
 *
 * 运行:
 *   npx hardhat run scripts/configureConetTreasuryPeerBridge.ts --network conet
 *   npx hardhat run scripts/configureConetTreasuryPeerBridge.ts --network base
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  CONET_TREASURY_CREATE2_PREDICTED,
  CONET_TREASURY_PEER_CREATE2_PREDICTED,
} from "./conetTreasuryDeployConstants.js";
import { BUINT_CREATE2_PREDICTED, BUINT_INITIAL_ADMIN } from "./bunitDeployConstants.js";
import { GB_CREATE2_PREDICTED } from "./gbDeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function readMeta(key: "conetTreasury-create2-meta" | "conetTreasuryPeer-create2-meta"): string | undefined {
  const p = path.join(__dirname, "..", "deployments", `${key}.json`);
  if (!fs.existsSync(p)) return undefined;
  return JSON.parse(fs.readFileSync(p, "utf-8")).predictedAddress as string | undefined;
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const treasuryAddr = ethers.getAddress(
    process.env.CONET_TREASURY || readMeta("conetTreasury-create2-meta") || CONET_TREASURY_CREATE2_PREDICTED
  );
  const peerAddr = ethers.getAddress(
    process.env.CONET_TREASURY_PEER || readMeta("conetTreasuryPeer-create2-meta") || CONET_TREASURY_PEER_CREATE2_PREDICTED
  );
  const buintAddr = ethers.getAddress(process.env.BUINT_ADDRESS?.trim() || BUINT_CREATE2_PREDICTED);
  const gbFromEnv = process.env.GB_ADDRESS?.trim();
  const addrJsonPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  const addrJson = fs.existsSync(addrJsonPath)
    ? (JSON.parse(fs.readFileSync(addrJsonPath, "utf-8")) as Record<string, string>)
    : {};
  const gbCandidate = gbFromEnv || addrJson.ConetGB1155 || GB_CREATE2_PREDICTED;
  let gbAddr = ethers.getAddress(gbCandidate);
  const gbCode = await ethers.provider.getCode(gbAddr);
  if (gbCode === "0x" || gbCode.length <= 2) {
    const fallback = ethers.getAddress(GB_CREATE2_PREDICTED);
    const fallbackCode = await ethers.provider.getCode(fallback);
    if (fallbackCode !== "0x" && fallbackCode.length > 2) {
      gbAddr = fallback;
    } else {
      console.warn(`[2] GB 地址无 code: ${gbAddr}；跳过 setConetGB / ISSUER（先 deployGBStackCreate2）`);
      gbAddr = ethers.ZeroAddress;
    }
  }

  const treasury = await ethers.getContractAt("ConetTreasury", treasuryAddr, signer);
  const peer = await ethers.getContractAt("ConetTreasuryPeer", peerAddr, signer);
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("Configure ConetTreasuryPeer bridge roles");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("signer:", signer.address);
  console.log("Treasury:", treasuryAddr);
  console.log("Peer:", peerAddr);

  const linkedPeer = await treasury.peerModule();
  if (linkedPeer.toLowerCase() !== peerAddr.toLowerCase()) {
    console.warn("⚠️ Treasury.peerModule 未指向 Peer；先 deployConetTreasuryStackCreate2 或 setPeerModule");
  }

  const currentBuint = await peer.buint();
  if (currentBuint.toLowerCase() !== buintAddr.toLowerCase()) {
    const tx = await peer.setBUint(buintAddr);
    await tx.wait();
    console.log("[1] Peer.setBUint:", buintAddr);
  } else {
    console.log("[1] Peer.buint 已配置");
  }

  const currentGb = await peer.conetGB();
  if (gbAddr !== ethers.ZeroAddress) {
    if (currentGb.toLowerCase() !== gbAddr.toLowerCase()) {
      const tx = await peer.setConetGB(gbAddr);
      await tx.wait();
      console.log("[2] Peer.setConetGB:", gbAddr);
    } else {
      console.log("[2] Peer.conetGB 已配置");
    }
  }

  if (process.env.SKIP_BUINT_ADMIN !== "1") {
    const buint = await ethers.getContractAt(
      ["function admins(address) view returns (bool)", "function addAdmin(address) external"],
      buintAddr
    );
    const peerIsAdmin = await buint.admins(peerAddr);
    if (!peerIsAdmin) {
      const adminSigner =
        signer.address.toLowerCase() === BUINT_INITIAL_ADMIN.toLowerCase()
          ? signer
          : await ethers.getSigner(BUINT_INITIAL_ADMIN).catch(() => null);
      if (!adminSigner) {
        console.warn(
          `[3] 跳过 BUint.addAdmin(Peer)：当前 signer 非 initialAdmin ${BUINT_INITIAL_ADMIN}；请手动 addAdmin(${peerAddr})`
        );
      } else {
        const tx = await buint.connect(adminSigner).addAdmin(peerAddr);
        await tx.wait();
        console.log("[3] BeamioBUnits.addAdmin(Peer) ok");
      }
    } else {
      console.log("[3] Peer 已是 BUint admin");
    }
  }

  if (process.env.SKIP_GB_ISSUER !== "1" && gbAddr !== ethers.ZeroAddress) {
    const issuerRole = ethers.id("ISSUER_ROLE");
    const gb = await ethers.getContractAt(
      ["function hasRole(bytes32,address) view returns (bool)", "function grantRole(bytes32,address) external"],
      gbAddr,
      signer
    );
    const peerIsIssuer = await gb.hasRole(issuerRole, peerAddr);
    if (!peerIsIssuer) {
      const tx = await gb.grantRole(issuerRole, peerAddr);
      await tx.wait();
      console.log("[4] ConetGB1155.grantRole(ISSUER_ROLE, Peer) ok");
    } else {
      console.log("[4] Peer 已是 GB ISSUER");
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
