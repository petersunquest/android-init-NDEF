/**
 * ConetTreasuryPeer 跨链桥 post-deploy（各链 CREATE2 同址 + setPeerModule 后执行）:
 *   Peer.setBUint / setGbTokenErc20 / setUsdcErc20（CoNET）/ setConetGB（**@deprecated** legacy 1155 可选）
 *   BeamioBUnits.addAdmin(Peer)
 *   GBToken.addAdmin(Peer) — **canonical** ERC20 GB mint/burn
 *   ConetGB1155.grantRole(ISSUER_ROLE, Peer) — **@deprecated** legacy B002 路径（可选；SKIP_GB_ISSUER=1 推荐）
 *
 * 环境变量:
 *   CONET_TREASURY / CONET_TREASURY_PEER — 覆盖地址
 *   BUINT_ADDRESS / GB_TOKEN_ERC20 / CONET_USDC / GB_ADDRESS — CREATE2 同址
 *   SKIP_BUINT_ADMIN=1 / SKIP_GB_TOKEN_ADMIN=1 / SKIP_GB_ISSUER=1
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
  CONET_USDC,
  GB_TOKEN_ERC20_CREATE2_PREDICTED,
} from "./conetTreasuryDeployConstants.js";
import { BUINT_UUPS_PROXY_PREDICTED, BUINT_INITIAL_ADMIN } from "./bunitDeployConstants.js";

/** legacy ConetGB1155（可选；无 code 时跳过） */
const GB_CREATE2_PREDICTED = "0x3Dc53e528d45225e8F38c391Cc6a72CDec435748";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function getAddressFromMetaOrDefault(metaKey: string, field: string, fallback: string): string {
  const p = path.join(__dirname, "..", "deployments", `${metaKey}.json`);
  if (fs.existsSync(p)) {
    const v = JSON.parse(fs.readFileSync(p, "utf-8"))[field] as string | undefined;
    if (v) return v;
  }
  return fallback;
}

const GB_TOKEN_INITIAL_ADMIN = getAddressFromMetaOrDefault(
  "gbToken-create2-meta",
  "initialAdmin",
  "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1"
);

function readMeta(key: "conetTreasury-create2-meta" | "conetTreasuryPeer-create2-meta"): string | undefined {
  const p = path.join(__dirname, "..", "deployments", `${key}.json`);
  if (!fs.existsSync(p)) return undefined;
  return JSON.parse(fs.readFileSync(p, "utf-8")).predictedAddress as string | undefined;
}

async function ensurePeerAdminOnToken(
  ethers: Awaited<ReturnType<typeof networkModule.connect>>["ethers"],
  tokenAddr: string,
  peerAddr: string,
  initialAdmin: string,
  label: string
) {
  const token = await ethers.getContractAt(
    ["function admins(address) view returns (bool)", "function addAdmin(address) external"],
    tokenAddr
  );
  const peerIsAdmin = await token.admins(peerAddr);
  if (peerIsAdmin) {
    console.log(`[${label}] Peer 已是 admin`);
    return;
  }
  const [signer] = await ethers.getSigners();
  const adminSigner =
    signer!.address.toLowerCase() === initialAdmin.toLowerCase()
      ? signer
      : await ethers.getSigner(initialAdmin).catch(() => null);
  if (!adminSigner) {
    console.warn(
      `[${label}] 跳过 addAdmin(Peer)：当前 signer 非 initialAdmin ${initialAdmin}；请手动 addAdmin(${peerAddr})`
    );
    return;
  }
  const tx = await token.connect(adminSigner).addAdmin(peerAddr);
  await tx.wait();
  console.log(`[${label}] addAdmin(Peer) ok`);
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
  const addrJsonPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
  const addrJson = fs.existsSync(addrJsonPath)
    ? (JSON.parse(fs.readFileSync(addrJsonPath, "utf-8")) as Record<string, string>)
    : {};
  const buintAddr = ethers.getAddress(
    process.env.BUINT_ADDRESS?.trim() || addrJson.BUint || BUINT_UUPS_PROXY_PREDICTED
  );
  const gbTokenErc20 = ethers.getAddress(
    process.env.GB_TOKEN_ERC20?.trim() || GB_TOKEN_ERC20_CREATE2_PREDICTED
  );
  const usdcErc20 = ethers.getAddress(process.env.CONET_USDC?.trim() || CONET_USDC);

  const gbFromEnv = process.env.GB_ADDRESS?.trim();
  const gb1155Candidate = gbFromEnv || addrJson.ConetGB1155 || GB_CREATE2_PREDICTED;
  let gb1155Addr = ethers.getAddress(gb1155Candidate);
  const gb1155Code = await ethers.provider.getCode(gb1155Addr);
  if (gb1155Code === "0x" || gb1155Code.length <= 2) {
    gb1155Addr = ethers.ZeroAddress;
  }

  const treasury = await ethers.getContractAt(
    ["function peerModule() view returns (address)", "function setPeerModule(address) external"],
    treasuryAddr,
    signer
  );
  const peer = await ethers.getContractAt("ConetTreasuryPeer", peerAddr, signer);
  const net = await ethers.provider.getNetwork();

  console.log("=".repeat(60));
  console.log("Configure ConetTreasuryPeer bridge roles");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("signer:", signer.address);
  console.log("Treasury:", treasuryAddr);
  console.log("Peer:", peerAddr);

  const linkedPeer = await treasury.peerModule().catch(() => ethers.ZeroAddress);
  if (linkedPeer === ethers.ZeroAddress || linkedPeer.toLowerCase() !== peerAddr.toLowerCase()) {
    const tx = await treasury.setPeerModule(peerAddr);
    await tx.wait();
    console.log("[0] Treasury.setPeerModule:", peerAddr);
  } else {
    console.log("[0] Treasury.peerModule 已指向 Peer");
  }

  const currentBuint = await peer.buint();
  if (currentBuint.toLowerCase() !== buintAddr.toLowerCase()) {
    const tx = await peer.setBUint(buintAddr);
    await tx.wait();
    console.log("[1] Peer.setBUint:", buintAddr);
  } else {
    console.log("[1] Peer.buint 已配置");
  }

  const currentGbToken = await peer.gbTokenErc20();
  if (currentGbToken.toLowerCase() !== gbTokenErc20.toLowerCase()) {
    const tx = await peer.setGbTokenErc20(gbTokenErc20);
    await tx.wait();
    console.log("[2] Peer.setGbTokenErc20:", gbTokenErc20);
  } else {
    console.log("[2] Peer.gbTokenErc20 已配置");
  }

  if (net.chainId === 224422n) {
    const currentUsdc = await peer.usdcErc20();
    if (currentUsdc.toLowerCase() !== usdcErc20.toLowerCase()) {
      const tx = await peer.setUsdcErc20(usdcErc20);
      await tx.wait();
      console.log("[3] Peer.setUsdcErc20:", usdcErc20);
    } else {
      console.log("[3] Peer.usdcErc20 已配置");
    }
    const targetRate = process.env.USDC6_PER_FULL_GB?.trim()
      ? BigInt(process.env.USDC6_PER_FULL_GB.trim())
      : 10_000n;
    const currentRate = await peer.usdc6PerFullGb();
    if (currentRate !== targetRate) {
      const tx = await peer.setUsdc6PerFullGb(targetRate);
      await tx.wait();
      console.log("[3b] Peer.setUsdc6PerFullGb:", targetRate.toString());
    } else {
      console.log("[3b] Peer.usdc6PerFullGb 已配置");
    }
  }

  if (gb1155Addr !== ethers.ZeroAddress) {
    const currentGb = await peer.conetGB();
    if (currentGb.toLowerCase() !== gb1155Addr.toLowerCase()) {
      const tx = await peer.setConetGB(gb1155Addr);
      await tx.wait();
      console.log("[4] Peer.setConetGB (legacy 1155):", gb1155Addr);
    } else {
      console.log("[4] Peer.conetGB (legacy) 已配置");
    }
  }

  if (process.env.SKIP_BUINT_ADMIN !== "1") {
    await ensurePeerAdminOnToken(ethers, buintAddr, peerAddr, BUINT_INITIAL_ADMIN, "5 BUint");
  }

  if (process.env.SKIP_GB_TOKEN_ADMIN !== "1") {
    const gbCode = await ethers.provider.getCode(gbTokenErc20);
    if (gbCode === "0x" || gbCode.length <= 2) {
      console.warn("[6] 跳过 GBToken.addAdmin：链上无 code");
    } else {
      await ensurePeerAdminOnToken(ethers, gbTokenErc20, peerAddr, GB_TOKEN_INITIAL_ADMIN, "6 GBToken");
    }
  }

  if (process.env.SKIP_GB_ISSUER !== "1" && gb1155Addr !== ethers.ZeroAddress) {
    const issuerRole = ethers.id("ISSUER_ROLE");
    const gb = await ethers.getContractAt(
      ["function hasRole(bytes32,address) view returns (bool)", "function grantRole(bytes32,address) external"],
      gb1155Addr,
      signer
    );
    const peerIsIssuer = await gb.hasRole(issuerRole, peerAddr);
    if (!peerIsIssuer) {
      const tx = await gb.grantRole(issuerRole, peerAddr);
      await tx.wait();
      console.log("[7] ConetGB1155.grantRole(ISSUER_ROLE, Peer) ok (legacy B002)");
    } else {
      console.log("[7] Peer 已是 GB1155 ISSUER (legacy)");
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
