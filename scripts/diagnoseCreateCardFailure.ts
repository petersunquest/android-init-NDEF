/**
 * 本地排查 createCard 失败（BM_DeployFailed 等）：
 * 1) admin 的 ETH 余额
 * 2) Factory / Deployer 配置与 code
 * 3) initCode 构建与 gateway 校验
 * 4) 可选：staticCall 模拟 createCardCollectionWithInitCode
 *
 * 运行：npx hardhat run scripts/diagnoseCreateCardFailure.ts --network base
 * 使用 ~/.master.json 的 settle_contractAdmin[0] 作为 admin 私钥执行 staticCall（若存在）；
 * 否则可设置 PRIVATE_KEY=0x... 或依赖 Hardhat 默认 signer。
 */
import { network as networkModule } from "hardhat";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { readFileSync, existsSync } from "fs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const CARD_OWNER = "0xe5f4205e9377CCc3684E4dBFB6CF67AE1721F27E";
const CURRENCY_CAD = 0;
const PRICE_E6 = 1_000_000n;
const BASE_CARD_FACTORY = "0xDdD5c17E549a4e66ca636a3c528ae8FAebb8692b";

function getMasterJsonPath(): string {
  const candidates = [
    path.join(homedir(), ".master.json"),
    process.env.HOME ? path.join(process.env.HOME, ".master.json") : "",
    process.env.USERPROFILE ? path.join(process.env.USERPROFILE, ".master.json") : "",
  ].filter(Boolean) as string[];
  return candidates.find((p) => existsSync(p)) ?? candidates[0] ?? path.join(homedir(), ".master.json");
}

function loadAdminFromMaster(): { privateKey: string } | null {
  const f = getMasterJsonPath();
  if (!existsSync(f)) return null;
  try {
    const data = JSON.parse(readFileSync(f, "utf-8"));
    const pks = data?.settle_contractAdmin;
    if (!Array.isArray(pks) || pks.length === 0) return null;
    const pk = String(pks[0]).trim();
    const key = pk.startsWith("0x") ? pk : `0x${pk}`;
    if (key.length < 64) return null;
    return { privateKey: key };
  } catch {
    return null;
  }
}

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;

  const masterAdmin = loadAdminFromMaster();
  const ADMIN = masterAdmin
    ? new ethers.Wallet(masterAdmin.privateKey).address
    : "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";

  console.log("========== createCard 本地排查（Base）==========\n");
  const hardhatBaseRpc = process.env.BASE_RPC_URL || "https://1rpc.io/base";
  console.log("  Base RPC (Hardhat):", hardhatBaseRpc);
  if (masterAdmin) {
    console.log("使用 ~/.master.json settle_contractAdmin[0] 作为 admin:", ADMIN, "\n");
  } else {
    const triedPath = getMasterJsonPath();
    console.log(
      "未读取到 ~/.master.json 或 settle_contractAdmin 为空；尝试路径:",
      triedPath,
      "存在:",
      existsSync(triedPath),
      "\n"
    );
  }

  // 1) admin ETH 余额
  const balance = await provider.getBalance(ADMIN);
  const balanceEther = ethers.formatEther(balance);
  console.log("1. admin 地址:", ADMIN);
  console.log("   ETH 余额:", balanceEther, "ETH");
  const balanceNum = Number(balanceEther);
  if (balanceNum < 0.001) {
    console.log("   ❌ 余额过低，CREATE 可能 gas 不足导致 BM_DeployFailed");
  } else if (balanceNum < 0.01) {
    console.log("   ⚠️ 余额偏少，建议保持 > 0.01 ETH");
  } else {
    console.log("   ✅ 余额充足");
  }
  console.log();

  // 2) Factory 与 Deployer
  const factoryCode = await provider.getCode(BASE_CARD_FACTORY);
  const factoryHasCode = factoryCode !== "0x" && factoryCode.length > 2;
  console.log("2. Card Factory:", BASE_CARD_FACTORY);
  console.log("   has code:", factoryHasCode ? "✅" : "❌ 无 code → constructor 会 UC_GlobalMisconfigured");
  if (!factoryHasCode) {
    console.log("\n   → 请确认 RPC 与链（Base 8453）正确，且该地址已部署 Factory");
    process.exit(1);
  }

  const factoryAbi = [
    "function deployer() view returns (address)",
    "function owner() view returns (address)",
    "function isPaymaster(address) view returns (bool)",
  ];
  const factory = new ethers.Contract(BASE_CARD_FACTORY, factoryAbi, provider);
  const [deployerAddr, factoryOwner] = await Promise.all([factory.deployer(), factory.owner()]);
  console.log("   owner:", factoryOwner);
  console.log("   deployer():", deployerAddr);

  const deployerCode = deployerAddr ? await provider.getCode(deployerAddr) : "0x";
  const deployerHasCode = deployerCode !== "0x" && deployerCode.length > 2;
  console.log("   deployer has code:", deployerHasCode ? "✅" : "❌");

  const deployerAbi = ["function factory() view returns (address)"];
  const deployer = new ethers.Contract(deployerAddr, deployerAbi, provider);
  const deployerFactory = await deployer.factory();
  const deployerPointsToFactory =
    deployerFactory && deployerFactory.toLowerCase() === BASE_CARD_FACTORY.toLowerCase();
  console.log("   deployer.factory() === Factory:", deployerPointsToFactory ? "✅" : "❌");
  if (!deployerPointsToFactory) {
    console.log("   → 运行 npm run set:card-deployer-factory:base");
  }

  const isPaymaster = await factory.isPaymaster(ADMIN);
  const isOwner = factoryOwner.toLowerCase() === ADMIN.toLowerCase();
  console.log("   admin 是 owner:", isOwner ? "✅" : "否");
  console.log("   admin 是 paymaster:", isPaymaster ? "✅" : "否");
  if (!isOwner && !isPaymaster) {
    console.log("   ❌ admin 既非 owner 也非 paymaster，无法调用 createCardCollectionWithInitCode");
  }
  console.log();

  // 3) initCode 构建与 gateway、EIP-170 / EIP-3860 长度
  const artifactPath = path.join(__dirname, "..", "src", "x402sdk", "src", "ABI", "BeamioUserCardArtifact.json");
  const fs = await import("fs");
  const EIP170_LIMIT = 24576;
  const EIP3860_INITCODE_LIMIT = 49152;
  if (!fs.existsSync(artifactPath)) {
    console.log("3. 未找到 BeamioUserCardArtifact.json，跳过 initCode 检查");
  } else {
    const raw = fs.readFileSync(artifactPath, "utf-8");
    const artifact = JSON.parse(raw) as { abi: ethers.InterfaceAbi; bytecode?: string; deployedBytecode?: string };
    if (!artifact?.bytecode) {
      console.log("3. artifact 无 bytecode，跳过 initCode 检查");
    } else {
      const runtimeBytes = (artifact.deployedBytecode || "").length;
      const runtimeLen = runtimeBytes >= 2 ? (runtimeBytes - 2) / 2 : 0;
      console.log("3. Runtime bytecode (EIP-170):", runtimeLen, "bytes, 限制 24576, OK:", runtimeLen <= EIP170_LIMIT);
      const uri = "https://api.beamio.io/metadata/";
      const cf = new ethers.ContractFactory(artifact.abi, artifact.bytecode);
      const deployTx = await cf.getDeployTransaction(uri, CURRENCY_CAD, PRICE_E6, CARD_OWNER, BASE_CARD_FACTORY);
      const initCode = deployTx?.data;
      if (!initCode || !initCode.startsWith("0x")) {
        console.log("   ❌ 无法生成 initCode（getDeployTransaction 返回空）");
      } else {
        const initCodeBytes = (initCode.length - 2) / 2;
        console.log("   Creation bytecode / initCode (EIP-3860):", initCodeBytes, "bytes, 限制 49152, OK:", initCodeBytes <= EIP3860_INITCODE_LIMIT);
        const gatewayInInitCode = BASE_CARD_FACTORY;
        const gatewayCode = await provider.getCode(gatewayInInitCode);
        console.log("   gateway（Factory）", gatewayInInitCode, "has code:", gatewayCode !== "0x" && gatewayCode.length > 2 ? "✅" : "❌");
        console.log("   initialOwner (cardOwner):", CARD_OWNER, "非零:", CARD_OWNER !== ethers.ZeroAddress);
      }
    }
  }
  console.log();

  // 4) staticCall 模拟（使用 ~/.master.json settle_contractAdmin[0] 或 Hardhat signer）
  const adminSigner = masterAdmin
    ? new ethers.Wallet(masterAdmin.privateKey, provider)
    : (await ethers.getSigners())[0];
  const signerAddr = adminSigner?.address?.toLowerCase();
  if (!signerAddr || signerAddr !== ADMIN.toLowerCase()) {
    console.log("4. staticCall 模拟：未使用 admin 私钥（当前 signer:", signerAddr || "无", "），跳过。");
    console.log("   若需模拟，请配置 ~/.master.json settle_contractAdmin[0] 或设置 PRIVATE_KEY 为 admin 私钥后重跑。");
  } else {
    console.log("4. staticCall 模拟 createCardCollectionWithInitCode（使用 admin 为 signer）...");
    const BeamioFactoryPaymasterArtifact = await import(
      path.join(__dirname, "..", "src", "x402sdk", "src", "ABI", "BeamioUserCardFactoryPaymaster.json")
    ).then((m: { default: unknown }) => m.default);
    const abi = Array.isArray(BeamioFactoryPaymasterArtifact)
      ? BeamioFactoryPaymasterArtifact
      : (BeamioFactoryPaymasterArtifact as { abi?: unknown[] }).abi ?? [];
    const factoryWithSigner = new ethers.Contract(BASE_CARD_FACTORY, abi, adminSigner);
    const artifactPath2 = path.join(__dirname, "..", "src", "x402sdk", "src", "ABI", "BeamioUserCardArtifact.json");
    const raw2 = fs.readFileSync(artifactPath2, "utf-8");
    const artifact2 = JSON.parse(raw2) as { abi: ethers.InterfaceAbi; bytecode?: string };
    const cf2 = new ethers.ContractFactory(artifact2.abi, artifact2.bytecode!);
    const deployTx2 = await cf2.getDeployTransaction(
      "https://api.beamio.io/metadata/",
      CURRENCY_CAD,
      PRICE_E6,
      CARD_OWNER,
      BASE_CARD_FACTORY
    );
    const initCode2 = deployTx2?.data;
    if (!initCode2) {
      console.log("   ❌ 无法生成 initCode");
    } else {
      try {
        await factoryWithSigner.createCardCollectionWithInitCode.staticCall(
          CARD_OWNER,
          CURRENCY_CAD,
          PRICE_E6,
          initCode2
        );
        console.log("   ✅ staticCall 成功，链上应可发卡");
      } catch (e: unknown) {
        const err = e as { data?: string; message?: string; shortMessage?: string };
        const data = err?.data ?? (e as { info?: { error?: { data?: string } } }).info?.error?.data;
        console.log("   ❌ staticCall revert:", err?.shortMessage ?? err?.message ?? String(e));
        if (data) console.log("   revert data:", typeof data === "string" ? data.slice(0, 80) : data);
      }
    }
  }

  console.log("\n========== 排查结束 ==========");
  console.log("若仍失败，请按 docs/CREATECARD-EIP170-SIZE-LIMIT.md 的「10 分钟内定位」步骤操作（revert data、双长度、高 gas、gateway/initialOwner 检查）。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
