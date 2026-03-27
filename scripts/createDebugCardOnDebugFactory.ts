/**
 * 在 DEBUG 工厂上创建测试卡（默认读 deployments/base-UserCardFactory-DEBUG.json）。
 * 支持无 tiers（createCardCollectionWithInitCode）或与失败笔类似的 AndTiers 路径。
 *
 *   npm run create:debug-card:base
 *
 * 环境变量：
 *   CARD_FACTORY          覆盖工厂地址（默认 DEBUG json）
 *   CARD_OWNER            卡 owner EOA（默认 signer；对齐 CoNET-SI 日志可设 0x513087820Af94A7f4d21bC5B68090f3080022E0e）
 *   DEBUG_WITH_TIERS=1    使用 createCardCollectionWithInitCodeAndTiers（与 CoNET 日志一致的两档：500e6 / 10e6 USDC，attr 0/1）
 *   INITCODE_LINK_MAINNET_LIBS=1  使用 src/x402sdk/src/ABI/BeamioUserCardArtifact.json 的 bytecode + linkReferences，
 *      与 deployments/base-BeamioUserCardLibraries.json 库地址经 linkBeamioUserCardBytecode 链接（与 CCSA/Master 一致）。
 *      勿仅用 Hardhat getContractFactory 链主网库：artifact 的 link FQN 与本地 artifacts 不同会导致 initCode keccak 与线上不一致。
 *   GAS_LIMIT             默认 8000000；CCSA 生产常用 8500000
 *   .env PRIVATE_KEY 须为 deployments/base-BeamioAccount.json 的 deployer（与 npm run deploy:base / CoNET Master 0x87cA… 一致）。
 *   核对：npm run print:beamio-account-deployer:base
 *   SKIP_BEAMIO_ACCOUNT_DEPLOYER_CHECK=1  跳过与 *-BeamioAccount.json deployer 的校验
 *   ALLOW_MASTER_JSON_SIGNER=1            无 PRIVATE_KEY 时回退 ~/.master.json settle_contractAdmin[0]（须即该 deployer）
 *   INITCODE_GATEWAY=0x...                 BeamioUserCard 构造参数 gateway（默认 = CARD_FACTORY）；须与 createCard 目标工厂一致
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { deployBeamioUserCardLibraries, beamioUserCardFactoryLibraries } from "./beamioUserCardLibraries.js";
import {
  ensureSignerMatchesBeamioAccountDeployerUnlessSkipped,
  getHardhatDeploySigner,
} from "./utils/hardhatDeploySigner.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const DEFAULT_URI = "https://beamio.app/api/metadata/0x";
const CAD_ENUM = 0;
const ONE_CAD_E6 = 1_000_000n;

async function main() {
  const { ethers } = await networkModule.connect();
  const signer = await getHardhatDeploySigner(ethers);
  await ensureSignerMatchesBeamioAccountDeployerUnlessSkipped(ethers, signer);

  const networkInfo = await ethers.provider.getNetwork();
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  let factoryAddr = (process.env.CARD_FACTORY || "").trim();
  if (!factoryAddr) {
    const debugPath = path.join(deploymentsDir, `${networkInfo.name}-UserCardFactory-DEBUG.json`);
    if (!fs.existsSync(debugPath)) {
      throw new Error(`Missing ${debugPath}. Run npm run deploy:debug-usercard-factory:base first.`);
    }
    const j = JSON.parse(fs.readFileSync(debugPath, "utf-8"));
    factoryAddr = j.contracts?.beamioUserCardFactoryPaymaster?.address;
  }
  if (!factoryAddr || !ethers.isAddress(factoryAddr)) {
    throw new Error("Invalid CARD_FACTORY / DEBUG json");
  }
  factoryAddr = ethers.getAddress(factoryAddr);

  const gatewayRaw = (process.env.INITCODE_GATEWAY || "").trim();
  const gatewayForInit = gatewayRaw
    ? ethers.getAddress(gatewayRaw)
    : factoryAddr;

  const cardOwner = process.env.CARD_OWNER
    ? ethers.getAddress(process.env.CARD_OWNER.trim())
    : signer.address;

  const cardFactory = await ethers.getContractAt("BeamioUserCardFactoryPaymasterV07", factoryAddr, signer);
  const factoryOwner = await cardFactory.owner();
  const isPm = await cardFactory.isPaymaster(signer.address);
  if (signer.address.toLowerCase() !== factoryOwner.toLowerCase() && !isPm) {
    throw new Error(`Signer not owner/paymaster. owner=${factoryOwner}`);
  }

  const useMainnetLibs =
    process.env.INITCODE_LINK_MAINNET_LIBS === "1" || process.env.INITCODE_LINK_MAINNET_LIBS === "true";
  let cardLibs: { BeamioUserCardFormattingLib: string; BeamioUserCardTransferLib: string };
  if (useMainnetLibs) {
    const libPath = path.join(deploymentsDir, "base-BeamioUserCardLibraries.json");
    if (!fs.existsSync(libPath)) {
      throw new Error(`INITCODE_LINK_MAINNET_LIBS requires ${libPath}`);
    }
    const lj = JSON.parse(fs.readFileSync(libPath, "utf-8")) as {
      contracts?: {
        beamioUserCardFormattingLib?: { address?: string };
        beamioUserCardTransferLib?: { address?: string };
      };
    };
    const f = lj.contracts?.beamioUserCardFormattingLib?.address;
    const t = lj.contracts?.beamioUserCardTransferLib?.address;
    if (!f || !t) throw new Error("base-BeamioUserCardLibraries.json missing lib addresses");
    cardLibs = { BeamioUserCardFormattingLib: ethers.getAddress(f), BeamioUserCardTransferLib: ethers.getAddress(t) };
    console.log("initCode libs (mainnet json):", cardLibs);
  } else {
    const deployed = await deployBeamioUserCardLibraries(ethers, signer);
    cardLibs = deployed;
    console.log("initCode libs (fresh deploy this run):", cardLibs);
  }

  let initCode: string;
  if (useMainnetLibs) {
    const artifactPath = path.join(__dirname, "..", "src", "x402sdk", "src", "ABI", "BeamioUserCardArtifact.json");
    if (!fs.existsSync(artifactPath)) {
      throw new Error(`INITCODE_LINK_MAINNET_LIBS requires synced artifact: ${artifactPath} (npm run compile && node scripts/syncBeamioUserCardToX402sdk.mjs)`);
    }
    const art = JSON.parse(fs.readFileSync(artifactPath, "utf8")) as {
      abi: unknown;
      bytecode: string;
      linkReferences: Record<string, Record<string, { length: number; start: number }[]>>;
    };
    if (!art.bytecode?.startsWith("0x") || !art.linkReferences) {
      throw new Error("BeamioUserCardArtifact.json: missing bytecode or linkReferences");
    }
    const { linkBeamioUserCardBytecode } = await import("./linkBeamioUserCardBytecode.mjs");
    const linkedBytecode = linkBeamioUserCardBytecode(art.bytecode, art.linkReferences, cardLibs);
    const cf = new ethers.ContractFactory(art.abi as ethers.InterfaceAbi, linkedBytecode);
    const deployTx = await cf.getDeployTransaction(
      DEFAULT_URI,
      CAD_ENUM,
      ONE_CAD_E6,
      cardOwner,
      gatewayForInit,
      0,
      false,
    );
    initCode = deployTx?.data as string;
    console.log("initCode build: x402sdk BeamioUserCardArtifact.json + linkBeamioUserCardBytecode (Master/CCSA parity)");
  } else {
    const BeamioUserCard = await ethers.getContractFactory(
      "BeamioUserCard",
      beamioUserCardFactoryLibraries({
        BeamioUserCardFormattingLib: cardLibs.BeamioUserCardFormattingLib,
        BeamioUserCardTransferLib: cardLibs.BeamioUserCardTransferLib,
      }),
    );
    const deployTx = await BeamioUserCard.getDeployTransaction(
      DEFAULT_URI,
      CAD_ENUM,
      ONE_CAD_E6,
      cardOwner,
      gatewayForInit,
      0,
      false,
    );
    initCode = deployTx?.data as string;
  }
  if (!initCode) throw new Error("initCode build failed");

  const initCodeLen = (initCode.length - 2) / 2;
  const initCodeHash = ethers.keccak256(initCode);
  console.log("initCode bytes:", initCodeLen, "keccak256:", initCodeHash);

  const gasLimit = BigInt(process.env.GAS_LIMIT || "8000000");
  const withTiers = process.env.DEBUG_WITH_TIERS === "1" || process.env.DEBUG_WITH_TIERS === "true";

  console.log("Factory (createCard target):", factoryAddr);
  console.log("InitCode gateway (constructor):", gatewayForInit);
  console.log("Signer:", signer.address);
  console.log("Card owner:", cardOwner);
  console.log("CAD enum:", CAD_ENUM, "price E6:", ONE_CAD_E6.toString());
  console.log("With tiers:", withTiers);
  console.log("Gas limit:", gasLimit.toString());

  async function logFactoryFailureFromReceipt(rec: { logs?: readonly { topics: readonly string[]; data: string }[] }) {
    for (const log of rec.logs ?? []) {
      try {
        const parsed = cardFactory.interface.parseLog({ topics: [...log.topics], data: log.data });
        if (parsed?.name === "DeployFailedStep") {
          console.error("DeployFailedStep(step):", String(parsed.args.step));
        }
        if (parsed?.name === "DeployFailedCreateDebug") {
          console.error("DeployFailedCreateDebug length:", String(parsed.args.initCodeLength));
          console.error("DeployFailedCreateDebug initCodeHash:", String(parsed.args.initCodeHash));
        }
      } catch {
        /* ignore */
      }
    }
  }

  let receipt: { status?: number | bigint; logs?: readonly { topics: readonly string[]; data: string }[]; hash?: string } | null;
  try {
    if (withTiers) {
      // Align with CoNET [BeamioCreateCard:tiers] normalizedTiersForChain: (minUsdc6, attr, tierExpirySeconds)
      const tiers: [bigint, bigint, bigint][] = [
        [500_000_000n, 0n, 0n],
        [10_000_000n, 1n, 0n],
      ];
      const tx = await cardFactory.createCardCollectionWithInitCodeAndTiers(
        cardOwner,
        CAD_ENUM,
        ONE_CAD_E6,
        initCode,
        tiers,
        { gasLimit },
      );
      receipt = await tx.wait();
    } else {
      const tx = await cardFactory.createCardCollectionWithInitCode(cardOwner, CAD_ENUM, ONE_CAD_E6, initCode, {
        gasLimit,
      });
      receipt = await tx.wait();
    }
  } catch (e: unknown) {
    const rec = (e as { receipt?: (typeof receipt) & object })?.receipt;
    if (rec) {
      console.error("--- Reverted; factory debug events (need DEBUG-deployed factory) ---");
      await logFactoryFailureFromReceipt(rec);
    }
    throw e;
  }

  if (!receipt) throw new Error("no receipt");
  if (Number(receipt.status) === 0) {
    console.error("--- status=0 ---");
    await logFactoryFailureFromReceipt(receipt);
    throw new Error("createCard reverted (status 0)");
  }

  let cardAddress: string | undefined;
  const iface = cardFactory.interface;
  for (const log of receipt.logs ?? []) {
    try {
      const parsed = iface.parseLog({ topics: log.topics as string[], data: log.data });
      if (parsed?.name === "CardDeployed") {
        cardAddress = (parsed.args as { card?: string }).card;
        break;
      }
    } catch {
      /* skip */
    }
  }
  if (!cardAddress) {
    const cards = await cardFactory.cardsOfOwner(cardOwner);
    if (cards.length > 0) cardAddress = cards[cards.length - 1];
  }
  if (!cardAddress) throw new Error("Could not resolve card address; check receipt / DeployFailedStep logs");

  console.log("OK card:", cardAddress);
  console.log("Tx:", receipt.hash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
