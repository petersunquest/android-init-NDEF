/**
 * 部署基础设施 CCSA 卡并添加 settle_contractAdmin 为 admin
 * - 不部署 BeamioAccount、BeamioOracle，使用已部署的
 * - 为指定用户（默认 0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61）创建 CCSA
 * - 部署完成后将 masterSetup.settle_contractAdmin 中所有地址添加为 CCSA 卡的 admin
 *
 * 用法:
 *   CARD_OWNER=0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61 npm run deploy:ccsa-and-admins:base
 *   或
 *   PRIVATE_KEY=<factory_owner_pk> CARD_OWNER_PK=<card_owner_pk> npx hardhat run scripts/deployCCSAAndAddAdmins.ts --network base
 *
 * 添加额外 admin（如 0xfb49c43f2444221fbcb1099929a907b3e4a4a15c）:
 *   EXTRA_ADMIN=0xfb49c43f2444221fbcb1099929a907b3e4a4a15c npm run deploy:ccsa-and-admins:base
 *
 * 配置:
 *   - PRIVATE_KEY: 工厂 owner 或 paymaster 私钥（用于 createCardCollectionWithInitCode）
 *   - CARD_OWNER_PK: CCSA 卡 owner 私钥（用于 addAdmin，必须与 CARD_OWNER 对应）
 *   - 若 CARD_OWNER 在 settle_contractAdmin 中，可仅设 PRIVATE_KEY 且使用同一把钥匙
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const DEFAULT_CARD_OWNER = "0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61";
const CAD_CURRENCY = 0;
const ONE_CAD_E6 = 1_000_000n;
const DEFAULT_URI = "https://beamio.app/api/metadata/0x";

const MASTER_PATH = path.join(homedir(), ".master.json");

function loadMasterSetup(): { settle_contractAdmin: string[] } {
  if (!fs.existsSync(MASTER_PATH)) {
    throw new Error("未找到 ~/.master.json，请配置 settle_contractAdmin");
  }
  const data = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  if (!data.settle_contractAdmin || !Array.isArray(data.settle_contractAdmin) || data.settle_contractAdmin.length === 0) {
    throw new Error("~/.master.json 中 settle_contractAdmin 为空或不是数组");
  }
  return {
    settle_contractAdmin: data.settle_contractAdmin.map((pk: string) => (pk.startsWith("0x") ? pk : `0x${pk}`)),
  };
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();

  const cardOwner = process.env.CARD_OWNER
    ? ethers.getAddress(process.env.CARD_OWNER)
    : ethers.getAddress(DEFAULT_CARD_OWNER);

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  // 优先使用 base-UserCardFactory.json（与当前 Base 主网一致）
  const factoryFile = path.join(deploymentsDir, "base-UserCardFactory.json");
  const fallbackFile = path.join(deploymentsDir, "base-FullAccountAndUserCard.json");
  const dataFile = fs.existsSync(factoryFile) ? factoryFile : fallbackFile;
  if (!fs.existsSync(dataFile)) {
    throw new Error("未找到 deployments/base-UserCardFactory.json 或 base-FullAccountAndUserCard.json");
  }
  const data = JSON.parse(fs.readFileSync(dataFile, "utf-8"));
  const cardFactoryAddress = data.contracts?.beamioUserCardFactoryPaymaster?.address;
  if (!cardFactoryAddress) {
    throw new Error("部署文件中缺少 beamioUserCardFactoryPaymaster 地址");
  }

  const cardFactory = await ethers.getContractAt(
    "BeamioUserCardFactoryPaymasterV07",
    cardFactoryAddress
  );
  const factoryOwner = await cardFactory.owner();
  const isPm = await cardFactory.isPaymaster(signer.address);
  if (signer.address.toLowerCase() !== factoryOwner.toLowerCase() && !isPm) {
    throw new Error(
      `当前 signer ${signer.address} 不是工厂 owner (${factoryOwner}) 且不是 paymaster，无法发卡`
    );
  }

  const gateway = cardFactoryAddress;
  const BeamioUserCard = await ethers.getContractFactory("BeamioUserCard");
  const deployTx = await BeamioUserCard.getDeployTransaction(
    DEFAULT_URI,
    CAD_CURRENCY,
    ONE_CAD_E6,
    cardOwner,
    gateway
  );
  const initCode = deployTx?.data;
  if (!initCode) throw new Error("Failed to build BeamioUserCard initCode");

  console.log("=".repeat(60));
  console.log("步骤 1: 创建 CCSA 卡");
  console.log("=".repeat(60));
  console.log("  Card Factory:", cardFactoryAddress);
  console.log("  Caller:", signer.address);
  console.log("  Card owner (EOA):", cardOwner);
  console.log("  Currency: CAD (0), Unit price: 1 CAD = 1 token (1e6)");
  console.log("  Gateway:", gateway);

  const tx = await cardFactory.createCardCollectionWithInitCode(
    cardOwner,
    CAD_CURRENCY,
    ONE_CAD_E6,
    initCode
  );
  const receipt = await tx.wait();
  if (!receipt) throw new Error("Transaction failed");

  let cardAddress: string | undefined;
  const iface = cardFactory.interface;
  for (const log of receipt.logs ?? []) {
    try {
      const parsed = iface.parseLog({ topics: log.topics as string[], data: log.data });
      if (parsed?.name === "CardDeployed") {
        cardAddress = parsed.args?.card ?? parsed.args?.userCard;
        break;
      }
    } catch {
      // skip
    }
  }
  if (!cardAddress && Array.isArray(await cardFactory.cardsOfOwner(cardOwner))) {
    const cards = await cardFactory.cardsOfOwner(cardOwner);
    if (cards.length > 0) cardAddress = cards[cards.length - 1];
  }
  if (!cardAddress || !ethers.isAddress(cardAddress)) {
    throw new Error("Could not resolve new card address from receipt");
  }

  console.log("\n✅ CCSA 卡已创建:", cardAddress);

  // ========== 步骤 2: 添加 settle_contractAdmin + EXTRA_ADMIN 为 admin ==========
  const master = loadMasterSetup();
  const adminAddresses = master.settle_contractAdmin.map((pk: string) => new (ethers.Wallet)(pk).address);
  const extraAdmin = process.env.EXTRA_ADMIN; // 如 0xfb49c43f2444221fbcb1099929a907b3e4a4a15c
  if (extraAdmin && ethers.isAddress(extraAdmin) && !adminAddresses.find((a) => a.toLowerCase() === extraAdmin.toLowerCase())) {
    adminAddresses.push(ethers.getAddress(extraAdmin));
  }

  console.log("\n" + "=".repeat(60));
  console.log("步骤 2: 添加 settle_contractAdmin 为 CCSA admin");
  console.log("=".repeat(60));
  console.log("  待添加地址数:", adminAddresses.length);
  adminAddresses.forEach((a, i) => console.log(`    ${i + 1}. ${a}`));

  // addAdmin 需要 owner 或 gateway 调用；gateway 是合约，需 owner 调用
  const provider = ethers.provider;
  const ownerPk = process.env.CARD_OWNER_PK;
  let adminSigner: Awaited<ReturnType<typeof ethers.getSigners>>[0];

  if (ownerPk) {
    adminSigner = new ethers.Wallet(ownerPk.startsWith("0x") ? ownerPk : `0x${ownerPk}`, provider);
    if (adminSigner.address.toLowerCase() !== cardOwner.toLowerCase()) {
      throw new Error(
        `CARD_OWNER_PK 对应的地址 ${adminSigner.address} 与卡 owner ${cardOwner} 不一致，addAdmin 会 revert`
      );
    }
  } else if (signer.address?.toLowerCase() === cardOwner.toLowerCase()) {
    adminSigner = signer;
  } else {
    throw new Error(
      "需设置 CARD_OWNER_PK（卡 owner 的私钥）以调用 addAdmin。当前 signer 不是卡 owner。"
    );
  }

  const userCard = await ethers.getContractAt("BeamioUserCard", cardAddress, adminSigner);

  for (let i = 0; i < adminAddresses.length; i++) {
    const addr = adminAddresses[i];
    const already = await userCard.isAdmin(addr);
    if (already) {
      console.log(`  [${i + 1}/${adminAddresses.length}] ${addr} 已是 admin，跳过`);
      continue;
    }
    // _addAdmin 要求 newThreshold <= adminList.length（添加后）；添加后长度为 currentCount+1
    const currentCount = (await userCard.adminList()).length;
    const newThreshold = currentCount + 1;
    const txAdd = await userCard.addAdmin(addr, newThreshold);
    console.log(`  [${i + 1}/${adminAddresses.length}] addAdmin(${addr}, ${newThreshold}) tx: ${txAdd.hash}`);
    await txAdd.wait();
    console.log(`    ✅ 已添加`);
  }

  console.log("\n" + "=".repeat(60));
  console.log("✅ 全部完成");
  console.log("=".repeat(60));
  console.log("  CCSA 卡地址:", cardAddress);
  console.log("  更新地址: NEW_CCSA_ADDRESS=" + cardAddress + " node scripts/replace-ccsa-address.js");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
