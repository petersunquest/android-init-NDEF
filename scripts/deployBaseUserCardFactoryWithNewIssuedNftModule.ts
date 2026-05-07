/**
 * Base 主网（或任意 Hardhat「base」network）：部署新版 BeamioUserCardIssuedNftModuleV1，
 * 再部署新版 BeamioUserCardFactoryPaymasterV07（constructor 沿用现有 Redeem/USDC/deployer/aaFactory）。
 * 随后由部署者对新工厂执行 set*，使各默认模块与同部署文件中的当前生产配置一致，
 * （Issued NFT 指向新模块，其余Governance/Faucet/Membership/AdminStatsQuery 沿用旧部署地址）。
 *
 * 依赖：`deployments/<network>-UserCardFactory.json`（含 beamioUserCardFactoryPaymaster 各字段）
 *   或未设置时使用环境变量：USDC / REDEEM_MODULE / DEPLOY / AA_FACTORY / QUOTE_HELPER
 *
 * 用法：
 *   npx hardhat run scripts/deployBaseUserCardFactoryWithNewIssuedNftModule.ts --network base
 *
 * 签名：与 deployUserCardFactory 相同（.env PRIVATE_KEY 或 ~/.master.json settle_contractAdmin[0]）
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { ethers as ethersLib, type Signer } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function loadSignerPk(): string {
  if (process.env.PRIVATE_KEY?.trim()) {
    const pk = process.env.PRIVATE_KEY.trim();
    return pk.startsWith("0x") ? pk : `0x${pk}`;
  }
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) throw new Error("未找到 PRIVATE_KEY，且 ~/.master.json 不存在");
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk || typeof pk !== "string") throw new Error("~/.master.json 缺少 settle_contractAdmin[0]");
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

function readDeployJson(networkName: string): Record<string, unknown> | null {
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const p = path.join(deploymentsDir, `${networkName}-UserCardFactory.json`);
  if (!fs.existsSync(p)) return null;
  try {
    return JSON.parse(fs.readFileSync(p, "utf-8")) as Record<string, unknown>;
  } catch {
    return null;
  }
}

async function main() {
  const { ethers } = await networkModule.connect();
  let deployer: Signer;
  const signers = await ethers.getSigners();
  if (signers.length > 0) deployer = signers[0];
  else deployer = new ethersLib.NonceManager(new ethersLib.Wallet(loadSignerPk(), ethers.provider));

  const networkInfo = await ethers.provider.getNetwork();
  const networkName = networkInfo.name;
  const chainId = Number(networkInfo.chainId);
  const deployerAddr = await deployer.getAddress();

  console.log("Network:", networkName, "chainId:", chainId);
  console.log("Deployer:", deployerAddr);

  const dep = readDeployJson(networkName);
  const fc = ((dep?.contracts as Record<string, unknown>)?.beamioUserCardFactoryPaymaster ?? {}) as Record<
    string,
    unknown
  >;

  const defaultUsdc =
    chainId === 8453 ? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" : "0x036CbD53842c5426634e7929541eC2318f3dCF7e";

  const USDC_ADDRESS = process.env.USDC_ADDRESS || (fc.usdc as string) || defaultUsdc;
  const REDEEM_MODULE_ADDRESS =
    process.env.REDEEM_MODULE_ADDRESS || (fc.redeemModule as string);
  const QUOTE_HELPER_ADDRESS =
    process.env.QUOTE_HELPER_ADDRESS || (fc.quoteHelper as string);
  const DEPLOYER_ADDRESS =
    process.env.DEPLOYER_ADDRESS || (fc.deployer as string);
  const AA_FACTORY_ADDRESS =
    process.env.AA_FACTORY_ADDRESS || (fc.aaFactory as string);
  const GOV_MODULE = process.env.GOVERNANCE_MODULE_ADDRESS || (fc.governanceModule as string);
  const FAUCET_MODULE = process.env.FAUCET_MODULE_ADDRESS || (fc.faucetModule as string);
  const MEMBER_MODULE = process.env.MEMBERSHIP_STATS_MODULE_ADDRESS || (fc.membershipStatsModule as string);
  const ADMIN_STATS_MODULE = process.env.ADMIN_STATS_QUERY_MODULE_ADDRESS || (fc.adminStatsQueryModule as string);
  const METADATA_BASE_URI =
    process.env.USER_CARD_METADATA_BASE_URI || (fc.metadataBaseURI as string) || "https://beamio.app/api/metadata/0x";

  const missing = [
    [!REDEEM_MODULE_ADDRESS, "REDEEM_MODULE / redeemModule from JSON"],
    [!QUOTE_HELPER_ADDRESS, "QUOTE_HELPER / quoteHelper from JSON"],
    [!DEPLOYER_ADDRESS, "DEPLOYER / deployer from JSON"],
    [!AA_FACTORY_ADDRESS, "AA_FACTORY / aaFactory from JSON"],
    [!GOV_MODULE, "GOVERNANCE_MODULE / governanceModule from JSON"],
    [!FAUCET_MODULE, "FAUCET_MODULE / faucetModule from JSON"],
    [!MEMBER_MODULE, "MEMBERSHIP_STATS_MODULE / membershipStatsModule from JSON"],
    [!ADMIN_STATS_MODULE, "ADMIN_STATS_QUERY_MODULE / adminStatsQueryModule from JSON"],
  ].filter((x) => x[0]) as [boolean, string][];

  if (missing.length > 0) {
    console.error("缺少依赖:");
    missing.forEach(([, msg]) => console.error(" ", msg));
    console.error("\n请先维护 deployments/", networkName + "-UserCardFactory.json 或导出上述环境变量。");
    process.exit(1);
  }

  // validate code
  for (const [name, addr] of Object.entries({
    redeem: REDEEM_MODULE_ADDRESS,
    quote: QUOTE_HELPER_ADDRESS,
    deployer: DEPLOYER_ADDRESS,
    aa: AA_FACTORY_ADDRESS,
    gov: GOV_MODULE,
    faucet: FAUCET_MODULE,
    member: MEMBER_MODULE,
    adminStats: ADMIN_STATS_MODULE,
  })) {
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") throw new Error(`${name} ${addr}: no bytecode`);
  }

  console.log("\n—— 1/3 部署 BeamioUserCardIssuedNftModuleV1 ——");
  const IssuedFac = await ethers.getContractFactory("BeamioUserCardIssuedNftModuleV1");
  const issued = await IssuedFac.connect(deployer).deploy();
  await issued.waitForDeployment();
  const issuedAddr = await issued.getAddress();
  console.log("IssuedNftModule:", issuedAddr);

  console.log("\n—— 2/3 部署 BeamioUserCardFactoryPaymasterV07 ——");
  const FactFac = await ethers.getContractFactory("BeamioUserCardFactoryPaymasterV07");
  const factory = await FactFac.connect(deployer).deploy(
    USDC_ADDRESS,
    REDEEM_MODULE_ADDRESS!,
    QUOTE_HELPER_ADDRESS!,
    DEPLOYER_ADDRESS!,
    AA_FACTORY_ADDRESS!,
    deployerAddr
  );
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("UserCard Factory:", factoryAddr);

  console.log("\n—— 3/3 Owner 绑定 default 模块并与生产一致 ——");
  await (await factory.connect(deployer).setIssuedNftModule(issuedAddr)).wait();
  console.log("setIssuedNftModule(", issuedAddr, ")");

  await (await factory.connect(deployer).setGovernanceModule(GOV_MODULE!)).wait();
  await (await factory.connect(deployer).setFaucetModule(FAUCET_MODULE!)).wait();
  await (await factory.connect(deployer).setMembershipStatsModule(MEMBER_MODULE!)).wait();
  await (await factory.connect(deployer).setAdminStatsQueryModule(ADMIN_STATS_MODULE!)).wait();
  await (await factory.connect(deployer).setMetadataBaseURI(METADATA_BASE_URI)).wait();
  console.log("Governance/Faucet/Membership/AdminStatsQuery + metadata URI set.");

  const outDir = path.join(__dirname, "..", "deployments");
  const outName = `${networkName}-UserCardFactory-NEW-${new Date().toISOString().slice(0, 10)}.json`;
  const outPath = path.join(outDir, outName);
  fs.mkdirSync(outDir, { recursive: true });
  const payload = {
    network: networkName,
    chainId: String(chainId),
    deployer: deployerAddr,
    timestamp: new Date().toISOString(),
    note: "New factory after IssuedNftUserSigClaim; update config/chainAddresses and paymaster allowlist manually.",
    previousFactory: fc.address ?? "",
    contracts: {
      beamioUserCardIssuedNftModule: {
        address: issuedAddr,
        transactionHash: issued.deploymentTransaction()?.hash,
      },
      beamioUserCardFactoryPaymaster: {
        address: factoryAddr,
        usdc: USDC_ADDRESS,
        redeemModule: REDEEM_MODULE_ADDRESS,
        quoteHelper: QUOTE_HELPER_ADDRESS,
        deployer: DEPLOYER_ADDRESS,
        aaFactory: AA_FACTORY_ADDRESS,
        governanceModule: GOV_MODULE,
        issuedNftModule: issuedAddr,
        faucetModule: FAUCET_MODULE,
        membershipStatsModule: MEMBER_MODULE,
        adminStatsQueryModule: ADMIN_STATS_MODULE,
        metadataBaseURI: METADATA_BASE_URI,
        owner: deployerAddr,
        transactionHash: factory.deploymentTransaction()?.hash,
      },
    },
  };
  fs.writeFileSync(outPath, JSON.stringify(payload, null, 2));
  console.log("\n✅ Written:", outPath);
  console.log("\n⚠️ 必做收尾：");
  console.log(
    "  1) Cluster/Master Paymaster：对新工厂 owner 调用 changePaymasterStatus(各节点 signer, true)（若非 owner 即 signer）",
  );
  console.log(
    "  2) BeamioAccount/Container 工厂的 setUserCard/setCardFactory ——若系统要求单一路由，请按需更新（本脚本不修改 AA 工厂）",
  );
  console.log("  3) 仓库内更新 CARD_FACTORY / BASE_CARD_FACTORY 常量 + 同步 ABI（syncBeamioUserCardToX402sdk）");
  console.log("  4) BaseScan：用 deployments/base-*-standard-input-FULL.json 验证新工厂与新 Issued 模块\n");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
