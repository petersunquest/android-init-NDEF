/**
 * 停用旧 BUnitAirdrop / BuintRedeemAirdrop（immutable 绑旧 BUint）：
 * 1. 旧 BUint.removeAdmin(旧 airdrop / redeem)
 * 2. BeamioIndexerDiamond.setAdmin(旧 airdrop, false)
 * 3. 将旧地址写入 conet-addresses.json DEPRECATED_* 列表
 *
 * 运行: npx hardhat run scripts/disableLegacyBUnitAirdropConet.ts --network conet
 *
 * 环境变量（可选）:
 *   LEGACY_BUINT / LEGACY_BUNIT_AIRDROP / LEGACY_BUINT_REDEEM_AIRDROP
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { getAddress } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ADDRESSES_PATH = path.join(__dirname, "..", "deployments", "conet-addresses.json");

const DEFAULT_LEGACY_BUINT = "0xa354CC4c414568Dd14F6d63b53013f35483427f0";
const DEFAULT_LEGACY_AIRDROP = "0xb9cf45AF87b16853c8F48a16b0495F030309e70f";
const DEFAULT_LEGACY_REDEEM = "0x02e954D352EB4C687AB066f0967E35D41E7721b6";

function pushDeprecated(list: string[] | undefined, addr: string): string[] {
  const out = [...(list || [])];
  const lower = addr.toLowerCase();
  if (!out.some((x) => x.toLowerCase() === lower)) out.push(addr);
  return out;
}

async function main() {
  const addrs = fs.existsSync(ADDRESSES_PATH)
    ? JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf-8"))
    : {};

  const legacyBuint = getAddress(process.env.LEGACY_BUINT || addrs.BUintLegacy || DEFAULT_LEGACY_BUINT);
  const legacyAirdrop = getAddress(
    process.env.LEGACY_BUNIT_AIRDROP || addrs.BUnitAirdropLegacy || DEFAULT_LEGACY_AIRDROP
  );
  const legacyRedeem = getAddress(
    process.env.LEGACY_BUINT_REDEEM_AIRDROP || addrs.BuintRedeemAirdropLegacy || DEFAULT_LEGACY_REDEEM
  );
  const indexerAddr = getAddress(addrs.BeamioIndexerDiamond);
  const newAirdrop = addrs.BUnitAirdrop ? getAddress(addrs.BUnitAirdrop) : null;
  const newRedeem = addrs.BuintRedeemAirdrop ? getAddress(addrs.BuintRedeemAirdrop) : null;

  if (newAirdrop && newAirdrop.toLowerCase() === legacyAirdrop.toLowerCase()) {
    throw new Error("conet-addresses.json BUnitAirdrop 仍是旧地址，请先部署新 airdrop 再停用旧合约");
  }
  if (newRedeem && newRedeem.toLowerCase() === legacyRedeem.toLowerCase()) {
    throw new Error("conet-addresses.json BuintRedeemAirdrop 仍是旧地址，请先部署新 redeem 再停用旧合约");
  }

  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  console.log("=".repeat(60));
  console.log("Disable legacy BUnitAirdrop / BuintRedeemAirdrop");
  console.log("=".repeat(60));
  console.log("signer:", signer.address);
  console.log("legacy BUint:", legacyBuint);
  console.log("legacy airdrop:", legacyAirdrop);
  console.log("legacy redeem:", legacyRedeem);
  console.log("indexer:", indexerAddr);

  const legacyToken = await ethers.getContractAt(
    [
      "function admins(address) view returns (bool)",
      "function removeAdmin(address account) external",
    ],
    legacyBuint,
    signer
  );

  if (!(await legacyToken.admins(signer.address))) {
    throw new Error(`signer ${signer.address} 不是旧 BUint admin，无法 removeAdmin`);
  }

  for (const [label, addr] of [
    ["airdrop", legacyAirdrop],
    ["redeem", legacyRedeem],
  ] as const) {
    const isAdmin = await legacyToken.admins(addr);
    if (!isAdmin) {
      console.log(`[1] legacy BUint.admins(${label}) already false`);
      continue;
    }
    const tx = await legacyToken.removeAdmin(addr);
    await tx.wait();
    console.log(`[1] legacy BUint.removeAdmin(${label}=${addr}) ok | tx:`, tx.hash);
  }

  const diamond = await ethers.getContractAt(
    [
      "function isAdmin(address) view returns (bool)",
      "function setAdmin(address admin, bool enabled) external",
      "function owner() view returns (address)",
    ],
    indexerAddr,
    signer
  );
  const diamondOwner = await diamond.owner();
  if (diamondOwner.toLowerCase() !== signer.address.toLowerCase()) {
    console.warn(`[2] signer 不是 Indexer owner (${diamondOwner})，跳过 setAdmin(false)`);
  } else if (await diamond.isAdmin(legacyAirdrop)) {
    const tx = await diamond.setAdmin(legacyAirdrop, false);
    await tx.wait();
    console.log("[2] Indexer.setAdmin(legacy airdrop, false) ok | tx:", tx.hash);
  } else {
    console.log("[2] Indexer.isAdmin(legacy airdrop) already false");
  }

  addrs.BUnitAirdropLegacy = legacyAirdrop;
  addrs.BuintRedeemAirdropLegacy = legacyRedeem;
  addrs.BUintLegacy = legacyBuint;
  addrs.DEPRECATED_BUINT = pushDeprecated(addrs.DEPRECATED_BUINT, legacyBuint);
  addrs.DEPRECATED_BUINT_AIRDROP = pushDeprecated(addrs.DEPRECATED_BUINT_AIRDROP, legacyAirdrop);
  addrs.DEPRECATED_BUINT_REDEEM_AIRDROP = pushDeprecated(
    addrs.DEPRECATED_BUINT_REDEEM_AIRDROP,
    legacyRedeem
  );
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(addrs, null, 2) + "\n", "utf-8");
  console.log("[3] updated conet-addresses.json legacy + DEPRECATED_* lists");

  console.log("\n✅ 旧 airdrop / redeem 已从旧 BUint admin 移除；API 须使用新地址");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
