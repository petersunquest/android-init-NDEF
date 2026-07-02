/**
 * 批量 initializeCardUserCumulativeStatTokens（四张默认商户卡，无需 API/biz）。
 *
 * 策略（按序尝试）：
 * 1. relayer 为卡 admin → 直连 card.initialize…（relayer 付 gas）
 * 2. factory 含 gatewayInvokeCard 且 relayer 为 paymaster/owner → gatewayInvokeCard
 * 3. OWNER_PRIVATE_KEY 或 OWNER_KEYS_FILE 与 card.owner 匹配 → factory.executeForOwner
 *
 * 读状态:
 *   npx hardhat run scripts/batchInitializeCardUserCumulativeStatConet.ts --network conet
 *
 * 执行:
 *   EXECUTE=1 npx hardhat run scripts/batchInitializeCardUserCumulativeStatConet.ts --network conet
 *
 * 多卡多 owner（JSON 文件，key=card 地址 checksum，value=0x 私钥）:
 *   EXECUTE=1 OWNER_KEYS_FILE=./deployments/conet-card-owner-keys.json npx hardhat run ...
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const CONET_CHAIN_ID = 224422;

const DEFAULT_CARDS = [
  "0xc06055AEEd896F832e602a5876D2Dbe1CB365A8A",
  "0xB24D242A320b8dd756572b410645FE41Cd07FC8C",
  "0xafE482D2612327a0D723544B9fB713C514a793a2",
  "0xD9fEdE7e4A53F5D4d2c5256B393F031159568596",
];

const USER_CUMUL_IFACE = new ethers.Interface([
  "function initializeCardUserCumulativeStatTokens()",
  "function cardUserCumulativeStatTokensInitialized() view returns (bool)",
  "function owner() view returns (address)",
  "function factoryGateway() view returns (address)",
  "function isAdmin(address) view returns (bool)",
]);

const FACTORY_IFACE = new ethers.Interface([
  "function gatewayInvokeCard(address cardAddr, bytes data) returns (bytes)",
  "function executeForOwner(address cardAddr, bytes data, uint256 deadline, bytes32 nonce, bytes ownerSignature)",
  "function isPaymaster(address) view returns (bool)",
  "function owner() view returns (address)",
]);

function loadRelayerPk(): string {
  if (process.env.RELAYER_PRIVATE_KEY?.trim()) {
    const v = process.env.RELAYER_PRIVATE_KEY.trim();
    return v.startsWith("0x") ? v : `0x${v}`;
  }
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) {
    throw new Error("未找到 RELAYER_PRIVATE_KEY 且 ~/.master.json 不存在");
  }
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk || typeof pk !== "string") throw new Error("缺少 settle_contractAdmin[0]");
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

function loadOwnerKeysByCard(hhEthers: typeof ethers): Map<string, string> {
  const map = new Map<string, string>();
  const file = process.env.OWNER_KEYS_FILE?.trim();
  if (file && fs.existsSync(file)) {
    const raw = JSON.parse(fs.readFileSync(file, "utf-8")) as Record<string, string>;
    for (const [card, pk] of Object.entries(raw)) {
      if (!pk?.trim()) continue;
      map.set(hhEthers.getAddress(card), pk.startsWith("0x") ? pk : `0x${pk}`);
    }
  }
  const single = process.env.OWNER_PRIVATE_KEY?.trim();
  if (single) {
    const pk = single.startsWith("0x") ? single : `0x${single}`;
    for (const card of DEFAULT_CARDS) {
      const norm = hhEthers.getAddress(card);
      if (!map.has(norm)) map.set(norm, pk);
    }
  }
  return map;
}

function parseCards(hhEthers: typeof ethers): string[] {
  const raw = process.env.CARD_ADDRESSES?.trim();
  const list = raw
    ? raw.split(/[,\s]+/).map((s) => s.trim()).filter(Boolean)
    : DEFAULT_CARDS;
  return list.map((c) => hhEthers.getAddress(c));
}

type Row = {
  card: string;
  owner: string;
  initializedBefore: boolean;
  initializedAfter: boolean;
  action: "skip" | "dry-run" | "sent" | "error";
  method?: "directAdmin" | "gatewayInvokeCard" | "executeForOwner";
  txHash?: string;
  error?: string;
};

async function readStatus(provider: ethers.Provider, card: string): Promise<{ owner: string; initialized: boolean }> {
  const reader = new ethers.Contract(card, USER_CUMUL_IFACE.fragments, provider);
  const [owner, initialized] = await Promise.all([
    reader.owner() as Promise<string>,
    reader.cardUserCumulativeStatTokensInitialized() as Promise<boolean>,
  ]);
  return { owner: ethers.getAddress(owner), initialized: !!initialized };
}

async function signExecuteForOwner(
  ownerWallet: ethers.Wallet,
  card: string,
  data: string,
  deadline: number,
  nonce: string,
  gateway: string,
): Promise<string> {
  const domain = {
    name: "BeamioUserCardFactory",
    version: "1",
    chainId: CONET_CHAIN_ID,
    verifyingContract: gateway,
  };
  const types = {
    ExecuteForOwner: [
      { name: "cardAddress", type: "address" },
      { name: "dataHash", type: "bytes32" },
      { name: "deadline", type: "uint256" },
      { name: "nonce", type: "bytes32" },
    ],
  };
  const nonceBytes =
    nonce.length === 66 && nonce.startsWith("0x")
      ? (nonce as `0x${string}`)
      : (ethers.keccak256(ethers.toUtf8Bytes(nonce)) as `0x${string}`);
  return ownerWallet.signTypedData(domain, types, {
    cardAddress: ethers.getAddress(card),
    dataHash: ethers.keccak256(data),
    deadline,
    nonce: nonceBytes,
  });
}

async function initOne(
  provider: ethers.Provider,
  relayer: ethers.Wallet,
  card: string,
  execute: boolean,
  ownerKeys: Map<string, string>,
): Promise<Row> {
  const { owner, initialized } = await readStatus(provider, card);
  const row: Row = {
    card: ethers.getAddress(card),
    owner,
    initializedBefore: initialized,
    initializedAfter: initialized,
    action: initialized ? "skip" : execute ? "sent" : "dry-run",
  };
  if (initialized || !execute) return row;

  const data = USER_CUMUL_IFACE.encodeFunctionData("initializeCardUserCumulativeStatTokens", []);
  const relayerAddr = await relayer.getAddress();
  const cardReader = new ethers.Contract(card, USER_CUMUL_IFACE.fragments, provider);

  try {
    const relayerIsAdmin = (await cardReader.isAdmin(relayerAddr)) as boolean;
    if (relayerIsAdmin) {
      const cardWriter = new ethers.Contract(card, USER_CUMUL_IFACE.fragments, relayer);
      const tx = await cardWriter.initializeCardUserCumulativeStatTokens();
      const receipt = await tx.wait();
      if (!receipt || receipt.status !== 1) throw new Error("directAdmin reverted");
      row.method = "directAdmin";
      row.txHash = tx.hash;
      const after = await readStatus(provider, card);
      row.initializedAfter = after.initialized;
      if (!after.initialized) throw new Error("tx ok but cardUserCumulativeStatTokensInitialized still false");
      return row;
    }

    const gateway = ethers.getAddress((await cardReader.factoryGateway()) as string);
    const factoryCode = await provider.getCode(gateway);
    const gwSelector = FACTORY_IFACE.getFunction("gatewayInvokeCard")!.selector.slice(2).toLowerCase();
    if (factoryCode.toLowerCase().includes(gwSelector)) {
      const factory = new ethers.Contract(gateway, FACTORY_IFACE.fragments, relayer);
      const [isPm, factoryOwner] = await Promise.all([
        factory.isPaymaster(relayerAddr) as Promise<boolean>,
        factory.owner() as Promise<string>,
      ]);
      if (isPm || ethers.getAddress(factoryOwner) === relayerAddr) {
        const tx = await factory.gatewayInvokeCard(card, data);
        const receipt = await tx.wait();
        if (!receipt || receipt.status !== 1) throw new Error("gatewayInvokeCard reverted");
        row.method = "gatewayInvokeCard";
        row.txHash = tx.hash;
        const after = await readStatus(provider, card);
        row.initializedAfter = after.initialized;
        if (!after.initialized) throw new Error("gateway tx ok but still uninitialized");
        return row;
      }
    }

    const ownerPk = ownerKeys.get(row.card);
    if (!ownerPk) {
      row.action = "error";
      row.error =
        "无可用路径：relayer 非卡 admin；factory 无 gatewayInvokeCard；未提供匹配的 OWNER_PRIVATE_KEY / OWNER_KEYS_FILE";
      return row;
    }
    const ownerWallet = new ethers.Wallet(ownerPk, provider);
    if (ownerWallet.address.toLowerCase() !== owner.toLowerCase()) {
      row.action = "error";
      row.error = `owner key ${ownerWallet.address} != card.owner ${owner}`;
      return row;
    }
    const deadline = Math.floor(Date.now() / 1000) + 900;
    const nonce = ethers.hexlify(ethers.randomBytes(32));
    const ownerSignature = await signExecuteForOwner(ownerWallet, card, data, deadline, nonce, gateway);
    const factory = new ethers.Contract(gateway, FACTORY_IFACE.fragments, relayer);
    const tx = await factory.executeForOwner(card, data, deadline, nonce, ownerSignature);
    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) throw new Error("executeForOwner reverted");
    row.method = "executeForOwner";
    row.txHash = tx.hash;
    const after = await readStatus(provider, card);
    row.initializedAfter = after.initialized;
    if (!after.initialized) throw new Error("executeForOwner ok but still uninitialized");
    return row;
  } catch (e: unknown) {
    row.action = "error";
    row.error = e instanceof Error ? e.message : String(e);
    return row;
  }
}

async function main() {
  const { ethers: hhEthers } = await networkModule.connect();
  const provider = hhEthers.provider;
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== CONET_CHAIN_ID) {
    throw new Error(`需要 CoNET ${CONET_CHAIN_ID}，当前 chainId=${network.chainId}`);
  }

  const execute = process.env.EXECUTE === "1" || process.env.EXECUTE === "true";
  const cards = parseCards(hhEthers);
  const relayer = new hhEthers.Wallet(loadRelayerPk(), provider);
  const ownerKeys = loadOwnerKeysByCard(hhEthers);

  console.log("=".repeat(72));
  console.log("batch initializeCardUserCumulativeStatTokens (CoNET)");
  console.log("=".repeat(72));
  console.log("relayer:", relayer.address);
  console.log("cards:", cards.length);
  console.log("execute:", execute);
  console.log("owner keys loaded:", ownerKeys.size);
  console.log();

  const rows: Row[] = [];
  for (const card of cards) {
    const row = await initOne(provider, relayer, card, execute, ownerKeys);
    rows.push(row);
    const line =
      row.action === "skip"
        ? "skip (already initialized)"
        : row.action === "dry-run"
          ? "dry-run"
          : row.action === "sent"
            ? `ok method=${row.method} tx=${row.txHash}`
            : `ERROR ${row.error}`;
    console.log(
      `${row.card} owner=${row.owner} before=${row.initializedBefore} after=${row.initializedAfter} → ${line}`,
    );
  }

  const outPath = path.join(
    __dirname,
    "..",
    "deployments",
    `conet-batch-user-cumulative-stat-init-${Date.now()}.json`,
  );
  const summary = {
    total: rows.length,
    initializedAfter: rows.filter((r) => r.initializedAfter).length,
    pending: rows.filter((r) => !r.initializedAfter).length,
    errors: rows.filter((r) => r.action === "error").length,
  };
  fs.writeFileSync(
    outPath,
    JSON.stringify({ timestamp: new Date().toISOString(), execute, relayer: relayer.address, rows, summary }, null, 2),
  );
  console.log();
  console.log("summary:", JSON.stringify(summary));
  console.log("wrote", outPath);

  if (summary.errors > 0) process.exitCode = 1;
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
