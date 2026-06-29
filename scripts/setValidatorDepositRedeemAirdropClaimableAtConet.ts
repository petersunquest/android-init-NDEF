/**
 * 设置 ValidatorDepositRedeem（CoNET）airdrop 的可领取开放时间（setAirdropClaimableAt），
 * 可选地为合约充值 CNET 以支付 airdrop（airdrop 直接来自本合约 CNET 余额）。
 *
 * setAirdropClaimableAt 为 onlyRedeemAdmin：签名者必须是 redeem admin。
 *
 * 用法:
 *   AIRDROP_CLAIMABLE_AT=1735689600 \
 *     npx hardhat run scripts/setValidatorDepositRedeemAirdropClaimableAtConet.ts --network conet
 *
 *   # 或用可读日期（UTC ISO-8601）
 *   AIRDROP_CLAIMABLE_AT_ISO=2026-08-01T00:00:00Z \
 *     npx hardhat run scripts/setValidatorDepositRedeemAirdropClaimableAtConet.ts --network conet
 *
 *   # 关闭领取（claimableAt = 0）
 *   AIRDROP_CLAIMABLE_AT=0 npx hardhat run scripts/...
 *
 *   # 同时充值合约 CNET（可独立使用，仅充值不改日期则省略上面两个变量）
 *   FUND_CNET=100000 npx hardhat run scripts/...
 *
 * 可选环境变量:
 *   VALIDATOR_DEPOSIT_REDEEM=0x…   覆盖 redeem 地址（默认 deployments/conet-addresses.json）
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

const REDEEM_ABI = [
  "function redeemAdmins(address account) view returns (bool)",
  "function setAirdropClaimableAt(uint64 claimableAt) external",
  "function airdropInfoOf(address beneficiary) view returns (uint256 accrued, uint256 claimed, uint256 claimable, uint64 claimableAt)",
] as const;

function loadRedeemAddress(): string {
  const env = process.env.VALIDATOR_DEPOSIT_REDEEM?.trim();
  if (env && ethers.isAddress(env)) return ethers.getAddress(env);
  const addrPath = path.join(root, "deployments", "conet-addresses.json");
  if (!fs.existsSync(addrPath)) throw new Error("缺少 deployments/conet-addresses.json");
  const data = JSON.parse(fs.readFileSync(addrPath, "utf-8")) as { ValidatorDepositRedeem?: string };
  const raw = data.ValidatorDepositRedeem?.trim();
  if (!raw || !ethers.isAddress(raw)) throw new Error("conet-addresses.json 缺少 ValidatorDepositRedeem");
  return ethers.getAddress(raw);
}

function resolveClaimableAt(): bigint | null {
  const iso = process.env.AIRDROP_CLAIMABLE_AT_ISO?.trim();
  if (iso) {
    const ms = Date.parse(iso);
    if (Number.isNaN(ms)) throw new Error(`AIRDROP_CLAIMABLE_AT_ISO 无法解析: ${iso}`);
    return BigInt(Math.floor(ms / 1000));
  }
  const raw = process.env.AIRDROP_CLAIMABLE_AT?.trim();
  if (raw === undefined || raw === "") return null;
  const n = BigInt(raw);
  if (n < 0n || n > 18446744073709551615n) throw new Error("AIRDROP_CLAIMABLE_AT 超出 uint64 范围");
  return n;
}

function resolveFundCnet(): bigint | null {
  const raw = process.env.FUND_CNET?.trim();
  if (!raw) return null;
  const v = ethers.parseEther(raw);
  if (v <= 0n) throw new Error("FUND_CNET 必须为正数");
  return v;
}

async function main() {
  const claimableAt = resolveClaimableAt();
  const fundCnet = resolveFundCnet();
  if (claimableAt === null && fundCnet === null) {
    throw new Error("请设置 AIRDROP_CLAIMABLE_AT / AIRDROP_CLAIMABLE_AT_ISO 或 FUND_CNET 至少一项");
  }

  const { ethers: ethersHH } = await networkModule.connect();
  const [signer] = await ethersHH.getSigners();
  const me = await signer.getAddress();
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  const redeemAddr = loadRedeemAddress();
  const c = new ethers.Contract(redeemAddr, REDEEM_ABI, signer);

  console.log("=".repeat(60));
  console.log("ValidatorDepositRedeem airdrop config (CoNET)");
  console.log("=".repeat(60));
  console.log("signer:", me);
  console.log("redeem:", redeemAddr);
  console.log("signer balance:", ethers.formatEther(await ethersHH.provider.getBalance(me)), "CNET");
  console.log("contract balance:", ethers.formatEther(await ethersHH.provider.getBalance(redeemAddr)), "CNET\n");

  if (fundCnet !== null) {
    console.log("fund contract →", ethers.formatEther(fundCnet), "CNET");
    const tx = await signer.sendTransaction({ to: redeemAddr, value: fundCnet });
    console.log("  tx:", tx.hash);
    await tx.wait();
    console.log(
      "  contract balance now:",
      ethers.formatEther(await ethersHH.provider.getBalance(redeemAddr)),
      "CNET\n",
    );
  }

  if (claimableAt !== null) {
    const iAm = (await c.redeemAdmins!(me)) as boolean;
    if (!iAm) {
      throw new Error(`签名者 ${me} 不是 redeem admin，无法 setAirdropClaimableAt`);
    }
    const human =
      claimableAt === 0n ? "0 (closed)" : `${claimableAt} (${new Date(Number(claimableAt) * 1000).toISOString()})`;
    console.log("setAirdropClaimableAt →", human);
    const tx = await c.setAirdropClaimableAt!(claimableAt);
    console.log("  tx:", tx.hash);
    await tx.wait();

    const info = await c.airdropInfoOf!(ethers.ZeroAddress);
    const onchain = info[3] as bigint;
    console.log("  on-chain claimableAt:", onchain.toString());
    if (onchain !== claimableAt) {
      throw new Error(`链上 claimableAt(${onchain}) 与期望(${claimableAt}) 不一致`);
    }
    console.log("  OK");
  }

  console.log("\nDone.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
