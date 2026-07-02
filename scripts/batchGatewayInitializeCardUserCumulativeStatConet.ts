/**
 * @deprecated CoNET 链上 Factory `0xfA52…` 无 `gatewayInvokeCard`，本脚本会失败。
 * 请改用 `scripts/batchInitializeCardUserCumulativeStatConet.ts`（relayer 为卡 admin 时直连；否则需 owner 签名）。
 *
 * 读状态:
 *   npx hardhat run scripts/batchGatewayInitializeCardUserCumulativeStatConet.ts --network conet
 *
 * 执行:
 *   EXECUTE=1 npx hardhat run scripts/batchGatewayInitializeCardUserCumulativeStatConet.ts --network conet
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { homedir } from "os";
import { ethers } from "ethers";

const CONET_CHAIN_ID = 224422;
const CONET_RPC = process.env.CONET_RPC_URL || "https://rpc1.conet.network";

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
]);

const FACTORY_IFACE = new ethers.Interface([
  "function gatewayInvokeCard(address cardAddr, bytes data) returns (bytes)",
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
  initialized: boolean;
  action: "skip" | "dry-run" | "sent" | "error";
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

async function gatewayInitOne(
  provider: ethers.Provider,
  relayer: ethers.Wallet,
  card: string,
  execute: boolean,
): Promise<Row> {
  const { owner, initialized } = await readStatus(provider, card);
  const row: Row = {
    card: ethers.getAddress(card),
    owner,
    initialized,
    action: initialized ? "skip" : execute ? "sent" : "dry-run",
  };
  if (initialized || !execute) return row;

  try {
    const cardReader = new ethers.Contract(card, USER_CUMUL_IFACE.fragments, provider);
    const gateway = ethers.getAddress((await cardReader.factoryGateway()) as string);
    const factory = new ethers.Contract(gateway, FACTORY_IFACE.fragments, relayer);
    const code = await provider.getCode(gateway);
    if (!code || code === "0x") throw new Error(`no bytecode at factory ${gateway}`);
    const gwSelector = FACTORY_IFACE.getFunction("gatewayInvokeCard")!.selector.slice(2).toLowerCase();
    if (!code.toLowerCase().includes(gwSelector)) {
      throw new Error(`factory ${gateway} missing gatewayInvokeCard`);
    }

    const relayerAddr = await relayer.getAddress();
    const [isPm, factoryOwner] = await Promise.all([
      factory.isPaymaster(relayerAddr) as Promise<boolean>,
      factory.owner() as Promise<string>,
    ]);
    if (!isPm && ethers.getAddress(factoryOwner) !== relayerAddr) {
      throw new Error(
        `relayer ${relayerAddr} is neither factory owner nor isPaymaster — use Master EntryPoint relay instead`,
      );
    }

    const cardCalldata = USER_CUMUL_IFACE.encodeFunctionData("initializeCardUserCumulativeStatTokens", []);
    const tx = await factory.gatewayInvokeCard(card, cardCalldata);
    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) {
      row.action = "error";
      row.error = "gatewayInvokeCard reverted";
      row.txHash = tx.hash;
      return row;
    }
    row.txHash = tx.hash;
    const after = await readStatus(provider, card);
    row.initialized = after.initialized;
    if (!after.initialized) {
      row.action = "error";
      row.error = "tx ok but cardUserCumulativeStatTokensInitialized still false";
    }
  } catch (e: unknown) {
    row.action = "error";
    row.error = e instanceof Error ? e.message : String(e);
  }
  return row;
}

async function main() {
  const { ethers: hhEthers } = await networkModule.connect();
  const network = await hhEthers.provider.getNetwork();
  if (Number(network.chainId) !== CONET_CHAIN_ID) {
    throw new Error(`需要 CoNET ${CONET_CHAIN_ID}，当前 chainId=${network.chainId}`);
  }

  const execute = process.env.EXECUTE === "1" || process.env.EXECUTE === "true";
  const cards = parseCards(hhEthers);
  const relayerPk = loadRelayerPk();
  const relayer = new hhEthers.Wallet(relayerPk, hhEthers.provider);

  console.log("=".repeat(72));
  console.log("batch gateway initializeCardUserCumulativeStatTokens");
  console.log("=".repeat(72));
  console.log("rpc:", CONET_RPC);
  console.log("relayer:", relayer.address);
  console.log("cards:", cards.length);
  console.log("execute:", execute);
  console.log();

  const rows: Row[] = [];
  for (const card of cards) {
    const row = await gatewayInitOne(hhEthers.provider, relayer, card, execute);
    rows.push(row);
    const line =
      row.action === "skip"
        ? "already initialized"
        : row.action === "dry-run"
          ? "would gateway-init"
          : row.action === "sent"
            ? `ok tx=${row.txHash}`
            : `ERROR ${row.error}`;
    console.log(`${row.card} owner=${row.owner} init=${row.initialized} → ${line}`);
  }

  console.log();
  const pending = rows.filter((r) => !r.initialized).length;
  const errors = rows.filter((r) => r.action === "error").length;
  console.log(`summary: total=${rows.length} initialized=${rows.length - pending} pending=${pending} errors=${errors}`);
  if (errors > 0) process.exitCode = 1;
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
