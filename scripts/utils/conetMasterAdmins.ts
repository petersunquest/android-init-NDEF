/**
 * 从 ~/.master.json 合并可用于 CoNET 部署/合约 addAdmin 的私钥列表：
 * settle_contractAdmin、beamio_Admins、admin（均为 0x + 64 位 hex 私钥，去重）。
 */
import { Wallet } from "ethers";
import * as fs from "fs";
import { homedir } from "os";
import * as path from "path";

const MASTER_PATH = path.join(homedir(), ".master.json");

function isPrivateKeyHex(s: string): boolean {
  const hex = s.startsWith("0x") ? s.slice(2) : s;
  return hex.length === 64 && /^[0-9a-fA-F]+$/.test(hex);
}

function normPk(s: string): string {
  return s.startsWith("0x") ? s : `0x${s}`;
}

/** 合并三类字段中的私钥；非私钥格式（如纯地址）会被忽略 */
export function mergeConetAdminPrivateKeysFromMasterFile(): string[] {
  if (!fs.existsSync(MASTER_PATH)) return [];
  let master: Record<string, unknown>;
  try {
    master = JSON.parse(fs.readFileSync(MASTER_PATH, "utf-8"));
  } catch {
    return [];
  }
  const settle = Array.isArray(master?.settle_contractAdmin) ? master.settle_contractAdmin : [];
  const beamio = Array.isArray(master?.beamio_Admins) ? master.beamio_Admins : [];
  const extra = Array.isArray(master?.admin) ? master.admin : [];
  const raw: string[] = [...settle, ...beamio, ...extra].filter((x): x is string => typeof x === "string");
  const keys = raw.filter(isPrivateKeyHex).map(normPk);
  return [...new Set(keys)];
}

/** 私钥对应的以太坊地址列表（去重，checksum 由调用方决定） */
export function mergeConetAdminAddressesFromMasterFile(): string[] {
  const pks = mergeConetAdminPrivateKeysFromMasterFile();
  const addrs = pks.map((pk) => new Wallet(pk).address);
  return [...new Set(addrs.map((a) => a.toLowerCase()))].map((a) => a); // 保持小写统一比较；需要 checksum 时用 getAddress
}
