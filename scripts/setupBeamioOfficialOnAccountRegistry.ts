/**
 * 在新部署的 AccountRegistry 上为 BeamioOfficial 钱包登记 @Beamio 账号。
 * 必要前置：addUserPoolProcess 在每个新用户注册后会尝试 followByAdmin BeamioOfficial。
 *           若 BeamioOfficial 自己在 registry 上没有 Account（exists=false），
 *           前置探测器会跳过，所有用户都无法 follow Beamio 官方账号。
 *
 * 用法：
 *   npx hardhat run scripts/setupBeamioOfficialOnAccountRegistry.ts --network conet
 *
 * 配置（按优先级）：
 *   - process.env.ACCOUNT_REGISTRY ：覆盖 registry 地址
 *   - deployments/conet-addresses.json 的 AccountRegistry
 *   - ~/.master.json BeamioOfficial：BeamioOfficial 私钥（用于本人签名）
 *   - ~/.master.json settle_contractAdmin[0] / beamio_Admins[0]：作为 admin fallback
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const CONET_RPC = process.env.CONET_RPC || "https://rpc1.conet.network";
const MASTER_PATH = path.join(homedir(), ".master.json");

const BEAMIO_OFFICIAL_ACCOUNT_NAME = "Beamio";

const RegistryABI = [
  "function isAdmin(address) view returns (bool)",
  "function getAccount(address) view returns (tuple(string accountName,string image,bool darkTheme,bool isUSDCFaucet,bool isETHFaucet,bool initialLoading,string firstName,string lastName,uint256 createdAt,bool exists,string pgpKeyID,string pgpKey))",
  "function setAccount(tuple(string accountName,string image,bool darkTheme,bool isUSDCFaucet,bool isETHFaucet,bool initialLoading,string firstName,string lastName,string pgpKeyID,string pgpKey) input) external",
  "function setAccountByAdmin(address to,tuple(string accountName,string image,bool darkTheme,bool isUSDCFaucet,bool isETHFaucet,bool initialLoading,string firstName,string lastName,string pgpKeyID,string pgpKey) input) external",
  "function isAccountNameAvailable(string) view returns (bool)",
  "function getOwnerByAccountName(string) view returns (address)",
];

function normPk(s: string): string {
  const t = s.trim();
  return t.startsWith("0x") ? t : `0x${t}`;
}
function isPkHex(s: string): boolean {
  const h = s.trim().startsWith("0x") ? s.trim().slice(2) : s.trim();
  return h.length === 64 && /^[0-9a-fA-F]+$/.test(h);
}

function getRegistryAddress(): string {
  if (process.env.ACCOUNT_REGISTRY) return ethers.getAddress(process.env.ACCOUNT_REGISTRY);
  const f = path.join(root, "deployments", "conet-addresses.json");
  if (fs.existsSync(f)) {
    const j = JSON.parse(fs.readFileSync(f, "utf-8"));
    if (j.AccountRegistry) return ethers.getAddress(j.AccountRegistry);
  }
  throw new Error("no AccountRegistry in env or deployments/conet-addresses.json");
}

function loadMaster(): { officialPk?: string; adminPk?: string } {
  if (!fs.existsSync(MASTER_PATH)) throw new Error("missing ~/.master.json");
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  const official = typeof data.BeamioOfficial === "string" ? normPk(data.BeamioOfficial) : undefined;
  const settleArr = Array.isArray(data.settle_contractAdmin) ? data.settle_contractAdmin : [];
  const beamioArr = Array.isArray(data.beamio_Admins) ? data.beamio_Admins : [];
  const adminPk = (settleArr[0] || beamioArr[0]) ? normPk(String(settleArr[0] || beamioArr[0])) : undefined;
  return {
    officialPk: official && isPkHex(official) ? official : undefined,
    adminPk: adminPk && isPkHex(adminPk) ? adminPk : undefined,
  };
}

async function main() {
  const provider = new ethers.JsonRpcProvider(CONET_RPC);
  const net = await provider.getNetwork();
  const registryAddr = getRegistryAddress();
  const code = await provider.getCode(registryAddr);
  if (code === "0x") throw new Error(`AccountRegistry has no code at ${registryAddr}`);

  const { officialPk, adminPk } = loadMaster();

  // BeamioOfficial 钱包地址（与 src/x402sdk/src/db.ts 中一致）。
  // 若本地 master.json 没有 BeamioOfficial 私钥（生产服务器才有），
  // 走 admin fallback：admin 签 setAccountByAdmin(officialAddr, ...) 即可。
  const FALLBACK_OFFICIAL_ADDR = "0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61";
  const officialWallet = officialPk ? new ethers.Wallet(officialPk, provider) : null;
  const officialAddr = officialWallet
    ? officialWallet.address
    : ethers.getAddress(FALLBACK_OFFICIAL_ADDR);

  console.log("=".repeat(60));
  console.log("Setup BeamioOfficial @Beamio on AccountRegistry");
  console.log("=".repeat(60));
  console.log("chainId:        ", net.chainId.toString());
  console.log("AccountRegistry:", registryAddr, "(code", (code.length - 2) / 2, "bytes)");
  console.log("BeamioOfficial: ", officialAddr, officialWallet ? "(self-sign available)" : "(admin fallback only)");

  const reg = new ethers.Contract(registryAddr, RegistryABI, provider);

  // 1) 检查现有状态
  let alreadyExists = false;
  try {
    const acc = await reg.getAccount(officialAddr);
    alreadyExists = !!acc?.exists;
    if (alreadyExists) {
      console.log("\n✅ Account already exists on chain:");
      console.log("   accountName:", acc.accountName);
      console.log("   createdAt:  ", new Date(Number(acc.createdAt) * 1000).toISOString());
      return;
    }
  } catch (ex: any) {
    const msg = ex?.shortMessage || ex?.message || "";
    if (!/AccountNotFound|execution reverted/i.test(msg)) {
      console.warn("getAccount probe unexpected error:", msg);
    }
  }

  // 2) 名字必须可用，或者已属于 BeamioOfficial 自己
  const owner: string = await reg.getOwnerByAccountName(BEAMIO_OFFICIAL_ACCOUNT_NAME);
  if (owner !== ethers.ZeroAddress && owner.toLowerCase() !== officialAddr.toLowerCase()) {
    throw new Error(
      `accountName "${BEAMIO_OFFICIAL_ACCOUNT_NAME}" is already taken by ${owner}, refusing to overwrite`
    );
  }

  const accountInput = {
    accountName: BEAMIO_OFFICIAL_ACCOUNT_NAME,
    image: "",
    darkTheme: false,
    isUSDCFaucet: false,
    isETHFaucet: false,
    initialLoading: false,
    firstName: "",
    lastName: "",
    pgpKeyID: "",
    pgpKey: "",
  };

  // 3) 优先用 BeamioOfficial 自己签名 setAccount（不需要 admin 权限）；
  //    没有私钥或没有 gas 时，走 admin → setAccountByAdmin
  const tryAdminFallback = async () => {
    if (!adminPk) {
      throw new Error(
        "无 admin fallback 私钥。请确保 ~/.master.json 中存在 settle_contractAdmin / beamio_Admins，且其中至少一个已是 AccountRegistry admin（先跑 addBeamioAdminsToAccountRegistry.ts）"
      );
    }
    const adminSigner = new ethers.Wallet(adminPk, provider);
    const adminIsAdmin = await reg.isAdmin(adminSigner.address);
    if (!adminIsAdmin) {
      throw new Error(
        `admin fallback signer ${adminSigner.address} is NOT registry admin. 先跑 npx hardhat run scripts/addBeamioAdminsToAccountRegistry.ts --network conet`
      );
    }
    console.log(`\n[fallback] using admin ${adminSigner.address} → setAccountByAdmin(${officialAddr}, ...)`);
    const c = reg.connect(adminSigner) as any;
    const tx = await c.setAccountByAdmin(officialAddr, accountInput);
    console.log("  tx:", tx.hash);
    await tx.wait();
    console.log("  ✅ setAccountByAdmin OK");
  };

  if (!officialWallet) {
    console.log("\n⚠️  BeamioOfficial 私钥不在本机 master.json，走 admin fallback…");
    await tryAdminFallback();
  } else {
    const officialBal = await provider.getBalance(officialAddr);
    console.log("BeamioOfficial balance:", ethers.formatEther(officialBal), "native");
    if (officialBal === 0n) {
      console.log("\n⚠️  BeamioOfficial 没有 native gas，走 admin fallback…");
      await tryAdminFallback();
    } else {
      try {
        const c = reg.connect(officialWallet) as any;
        console.log("\n[self] BeamioOfficial → setAccount(@Beamio)");
        const tx = await c.setAccount(accountInput);
        console.log("  tx:", tx.hash);
        await tx.wait();
        console.log("  ✅ setAccount OK");
      } catch (ex: any) {
        const msg = ex?.shortMessage || ex?.message || String(ex);
        console.warn("self-sign setAccount failed:", msg);
        console.log("→ 尝试 admin fallback…");
        await tryAdminFallback();
      }
    }
  }

  // 4) 验证
  const acc = await reg.getAccount(officialAddr);
  console.log("\n--- post-write verification ---");
  console.log("exists:     ", acc.exists);
  console.log("accountName:", acc.accountName);
  console.log("createdAt:  ", new Date(Number(acc.createdAt) * 1000).toISOString());
  if (!acc.exists || acc.accountName !== BEAMIO_OFFICIAL_ACCOUNT_NAME) {
    throw new Error("post-write verification failed");
  }
  console.log("\n✅ DONE — followBeamioOfficial 现在会成功");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
