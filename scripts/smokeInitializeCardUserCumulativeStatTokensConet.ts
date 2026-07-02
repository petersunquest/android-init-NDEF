/**
 * 每张商户卡 smoke：读/写 initializeCardUserCumulativeStatTokens + 可选 bootstrapIssuedNftV2StatTokens。
 *
 * 运行（仅读状态，默认）:
 *   CARD_ADDRESSES=0xabc...,0xdef... npx hardhat run scripts/smokeInitializeCardUserCumulativeStatTokensConet.ts --network conet
 *
 * 链上执行 initialize（卡主签名 + relayer 付 gas）:
 *   EXECUTE=1 OWNER_PRIVATE_KEY=0x... CARD_ADDRESSES=0x... npx hardhat run scripts/smokeInitializeCardUserCumulativeStatTokensConet.ts --network conet
 *
 * 可选 bootstrap（须已 initialize）:
 *   BOOTSTRAP_PARENT_IDS=100000000001,100000000002
 *
 * 走 Cluster API（须本地 beamioServer :2222）:
 *   USE_API=1 API_BASE=http://127.0.0.1:2222 OWNER_PRIVATE_KEY=0x... CARD_ADDRESSES=0x... EXECUTE=1 npx hardhat run ...
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ISSUED_NFT_START_ID = 100_000_000_000n;
const CONET_CHAIN_ID = 224422;

const USER_CUMUL_IFACE = new ethers.Interface([
  "function initializeCardUserCumulativeStatTokens()",
  "function bootstrapIssuedNftV2StatTokens(uint256 parentTokenId)",
  "function cardUserCumulativeStatTokensInitialized() view returns (bool)",
  "function owner() view returns (address)",
]);

function loadRelayerPk(): string {
  if (process.env.RELAYER_PRIVATE_KEY?.trim()) {
    const v = process.env.RELAYER_PRIVATE_KEY.trim();
    return v.startsWith("0x") ? v : `0x${v}`;
  }
  if (process.env.PRIVATE_KEY?.trim()) {
    const v = process.env.PRIVATE_KEY.trim();
    return v.startsWith("0x") ? v : `0x${v}`;
  }
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) {
    throw new Error("未找到 RELAYER_PRIVATE_KEY / PRIVATE_KEY，且 ~/.master.json 不存在");
  }
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk || typeof pk !== "string") {
    throw new Error("缺少 settle_contractAdmin[0]");
  }
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

function loadOwnerPk(): string | null {
  const v = process.env.OWNER_PRIVATE_KEY?.trim();
  if (!v) return null;
  return v.startsWith("0x") ? v : `0x${v}`;
}

function parseCardAddresses(): string[] {
  const raw = process.env.CARD_ADDRESSES?.trim();
  if (!raw) {
    const listPath = process.env.CARD_LIST_FILE?.trim();
    if (listPath && fs.existsSync(listPath)) {
      const parsed = JSON.parse(fs.readFileSync(listPath, "utf-8")) as unknown;
      if (Array.isArray(parsed)) {
        return parsed.map((x) => String(x).trim()).filter(Boolean);
      }
    }
    throw new Error("请设置 CARD_ADDRESSES（逗号分隔）或 CARD_LIST_FILE（JSON 数组）");
  }
  return raw
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function parseBootstrapParentIds(): bigint[] {
  const raw = process.env.BOOTSTRAP_PARENT_IDS?.trim();
  if (!raw) return [];
  return raw
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => BigInt(s));
}

async function readGateway(provider: ethers.Provider, card: string): Promise<string> {
  const cardReader = new ethers.Contract(
    card,
    ["function factoryGateway() view returns (address)"],
    provider,
  );
  const gw = (await cardReader.factoryGateway()) as string;
  if (!gw || gw === ethers.ZeroAddress) throw new Error(`card ${card} factoryGateway() is zero`);
  return ethers.getAddress(gw);
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
  const dataHash = ethers.keccak256(data);
  const nonceBytes =
    nonce.length === 66 && nonce.startsWith("0x")
      ? (nonce as `0x${string}`)
      : (ethers.keccak256(ethers.toUtf8Bytes(nonce)) as `0x${string}`);
  const value = {
    cardAddress: ethers.getAddress(card),
    dataHash,
    deadline,
    nonce: nonceBytes,
  };
  return ownerWallet.signTypedData(domain, types, value);
}

type RowResult = {
  card: string;
  owner: string;
  initialized: boolean;
  initAction: "skip" | "dry-run" | "sent" | "error" | "api";
  initTxHash?: string;
  initError?: string;
  bootstrap: { parentTokenId: string; action: string; txHash?: string; error?: string }[];
};

async function postApi(
  base: string,
  path: string,
  body: Record<string, unknown>,
): Promise<{ ok: boolean; status: number; json: Record<string, unknown> }> {
  const res = await fetch(`${base.replace(/\/$/, "")}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;
  return { ok: res.ok, status: res.status, json };
}

async function processCard(
  provider: ethers.Provider,
  relayer: ethers.Wallet,
  ownerWallet: ethers.Wallet | null,
  cardRaw: string,
  execute: boolean,
  useApi: boolean,
  apiBase: string,
  bootstrapIds: bigint[],
): Promise<RowResult> {
  const card = ethers.getAddress(cardRaw);
  const reader = new ethers.Contract(card, USER_CUMUL_IFACE.fragments, provider);
  const [owner, initialized] = await Promise.all([
    reader.owner() as Promise<string>,
    reader.cardUserCumulativeStatTokensInitialized() as Promise<boolean>,
  ]);
  const ownerAddr = ethers.getAddress(owner);

  const row: RowResult = {
    card,
    owner: ownerAddr,
    initialized: !!initialized,
    initAction: initialized ? "skip" : execute ? (useApi ? "api" : "sent") : "dry-run",
    bootstrap: [],
  };

  if (initialized) {
    row.initAction = "skip";
  } else if (!execute) {
    row.initAction = "dry-run";
  } else if (!ownerWallet) {
    row.initAction = "error";
    row.initError = "EXECUTE=1 需要 OWNER_PRIVATE_KEY（须为 card owner）";
    return row;
  } else if (ownerWallet.address.toLowerCase() !== ownerAddr.toLowerCase()) {
    row.initAction = "error";
    row.initError = `OWNER_PRIVATE_KEY 地址 ${ownerWallet.address} != card.owner ${ownerAddr}`;
    return row;
  } else {
    const data = USER_CUMUL_IFACE.encodeFunctionData("initializeCardUserCumulativeStatTokens", []);
    const deadline = Math.floor(Date.now() / 1000) + 900;
    const nonce = ethers.hexlify(ethers.randomBytes(32));
    const gateway = await readGateway(provider, card);
    const ownerSignature = await signExecuteForOwner(ownerWallet, card, data, deadline, nonce, gateway);

    try {
      if (useApi) {
        const r = await postApi(apiBase, "/api/cardInitializeUserCumulativeStat", {
          cardAddress: card,
          deadline,
          nonce,
          ownerSignature,
        });
        if (!r.ok) {
          row.initAction = "error";
          row.initError = String(r.json.error ?? `HTTP ${r.status}`);
        } else {
          row.initTxHash = String(r.json.hash ?? r.json.txHash ?? "");
          row.initialized = true;
        }
      } else {
        const factory = new ethers.Contract(
          gateway,
          ["function executeForOwner(address,bytes,uint256,bytes32,bytes)"],
          relayer,
        );
        const tx = await factory.executeForOwner(card, data, deadline, nonce, ownerSignature);
        const receipt = await tx.wait();
        if (!receipt || receipt.status !== 1) throw new Error("executeForOwner reverted");
        row.initTxHash = tx.hash;
        row.initialized = true;
      }
    } catch (e: unknown) {
      row.initAction = "error";
      row.initError = e instanceof Error ? e.message : String(e);
    }
  }

  const canBootstrap = row.initialized || initialized;
  if (!canBootstrap || bootstrapIds.length === 0) return row;

  for (const parentId of bootstrapIds) {
    const bootEntry = {
      parentTokenId: parentId.toString(),
      action: execute ? (useApi ? "api" : "sent") : "dry-run",
    } as RowResult["bootstrap"][number];
    if (parentId < ISSUED_NFT_START_ID) {
      bootEntry.action = "error";
      bootEntry.error = `parentTokenId < ${ISSUED_NFT_START_ID}`;
      row.bootstrap.push(bootEntry);
      continue;
    }
    if (!execute) {
      row.bootstrap.push(bootEntry);
      continue;
    }
    if (!ownerWallet) {
      bootEntry.action = "error";
      bootEntry.error = "missing OWNER_PRIVATE_KEY";
      row.bootstrap.push(bootEntry);
      continue;
    }
    const data = USER_CUMUL_IFACE.encodeFunctionData("bootstrapIssuedNftV2StatTokens", [parentId]);
    const deadline = Math.floor(Date.now() / 1000) + 900;
    const nonce = ethers.hexlify(ethers.randomBytes(32));
    const gateway = await readGateway(provider, card);
    const ownerSignature = await signExecuteForOwner(ownerWallet, card, data, deadline, nonce, gateway);
    try {
      if (useApi) {
        const r = await postApi(apiBase, "/api/cardBootstrapIssuedNftV2Stat", {
          cardAddress: card,
          parentTokenId: parentId.toString(),
          deadline,
          nonce,
          ownerSignature,
        });
        if (!r.ok) {
          bootEntry.action = "error";
          bootEntry.error = String(r.json.error ?? `HTTP ${r.status}`);
        } else {
          bootEntry.txHash = String(r.json.hash ?? r.json.txHash ?? "");
        }
      } else {
        const factory = new ethers.Contract(
          gateway,
          ["function executeForOwner(address,bytes,uint256,bytes32,bytes)"],
          relayer,
        );
        const tx = await factory.executeForOwner(card, data, deadline, nonce, ownerSignature);
        const receipt = await tx.wait();
        if (!receipt || receipt.status !== 1) throw new Error("bootstrap executeForOwner reverted");
        bootEntry.txHash = tx.hash;
      }
    } catch (e: unknown) {
      bootEntry.action = "error";
      bootEntry.error = e instanceof Error ? e.message : String(e);
    }
    row.bootstrap.push(bootEntry);
  }

  return row;
}

async function main() {
  const { ethers: hhEthers } = await networkModule.connect();
  const provider = hhEthers.provider;
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== CONET_CHAIN_ID) {
    throw new Error(`本脚本仅用于 CoNET ${CONET_CHAIN_ID}，当前 chainId=${network.chainId}`);
  }

  const cards = parseCardAddresses().map((c) => hhEthers.getAddress(c));
  const execute = process.env.EXECUTE === "1" || process.env.EXECUTE === "true";
  const useApi = process.env.USE_API === "1" || process.env.USE_API === "true";
  const apiBase = process.env.API_BASE?.trim() || "http://127.0.0.1:2222";
  const bootstrapIds = parseBootstrapParentIds();

  const relayerPk = loadRelayerPk();
  const relayer = new hhEthers.Wallet(relayerPk, provider);
  const ownerPk = loadOwnerPk();
  const ownerWallet = ownerPk ? new hhEthers.Wallet(ownerPk, provider) : null;

  console.log("=".repeat(72));
  console.log("smoke: initializeCardUserCumulativeStatTokens (CoNET merchant cards)");
  console.log("=".repeat(72));
  console.log("relayer:", relayer.address);
  console.log("owner signer:", ownerWallet?.address ?? "(none — read-only unless EXECUTE)");
  console.log("cards:", cards.length);
  console.log("execute:", execute, useApi ? `(via API ${apiBase})` : "(direct executeForOwner)");
  if (bootstrapIds.length) console.log("bootstrap parentTokenIds:", bootstrapIds.map(String).join(", "));
  console.log();

  const results: RowResult[] = [];
  for (const card of cards) {
    const row = await processCard(
      provider,
      relayer,
      ownerWallet,
      card,
      execute,
      useApi,
      apiBase,
      bootstrapIds,
    );
    results.push(row);
    const initLine =
      row.initAction === "skip"
        ? "init=skip (already initialized)"
        : row.initAction === "dry-run"
          ? "init=dry-run (would call initializeCardUserCumulativeStatTokens)"
          : row.initAction === "error"
            ? `init=ERROR ${row.initError}`
            : `init=ok tx=${row.initTxHash ?? "pending"}`;
    console.log(`${card} owner=${row.owner} initialized=${row.initialized} | ${initLine}`);
    for (const b of row.bootstrap) {
      console.log(`  bootstrap parent=${b.parentTokenId} action=${b.action}${b.txHash ? ` tx=${b.txHash}` : ""}${b.error ? ` err=${b.error}` : ""}`);
    }
  }

  const summary = {
    total: results.length,
    alreadyInitialized: results.filter((r) => r.initAction === "skip").length,
    dryRun: results.filter((r) => r.initAction === "dry-run").length,
    sent: results.filter((r) => r.initTxHash).length,
    errors: results.filter((r) => r.initAction === "error").length,
  };
  console.log();
  console.log("summary:", JSON.stringify(summary));

  const outPath = path.join(
    __dirname,
    "..",
    "deployments",
    `conet-smoke-user-cumulative-stat-${Date.now()}.json`,
  );
  fs.writeFileSync(
    outPath,
    JSON.stringify({ timestamp: new Date().toISOString(), execute, useApi, results, summary }, null, 2),
  );
  console.log("wrote", outPath);

  if (summary.errors > 0) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
