/**
 * CoNET Blockscout 验证 BuintRedeemAirdrop（递归依赖 Standard JSON，与 verifyBusinessStartKetStackOnScan 同源）
 *
 * 运行: npx tsx scripts/verifyBuintRedeemAirdropOnScan.ts
 */

import * as fs from "fs";
import * as path from "path";
import { AbiCoder, getAddress } from "ethers";
import { fileURLToPath } from "url";
import {
  BASESCAN_COMPILER_VERSION,
  exportBasescanStandardJsonFromRoot,
} from "./basescanStandardJsonShared.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");

const BLOCKSCOUT_API = (process.env.CONET_BLOCKSCOUT_API || "https://scan.conet.network/api").replace(/\/$/, "");
const BLOCKSCOUT_UI = (process.env.CONET_BLOCKSCOUT_UI || "https://scan.conet.network").replace(/\/$/, "");
const COMPILER_VERSION = `v${BASESCAN_COMPILER_VERSION}`;

async function checkVerified(address: string): Promise<boolean> {
  const res = await fetch(`${BLOCKSCOUT_API}/v2/smart-contracts/${address}`);
  if (!res.ok) return false;
  const data = (await res.json()) as { is_verified?: boolean };
  return Boolean(data.is_verified);
}

async function main() {
  const deployPath = path.join(root, "deployments/conet-BuintRedeemAirdrop.json");
  const deploy = JSON.parse(fs.readFileSync(deployPath, "utf-8")) as {
    contracts?: { BuintRedeemAirdrop?: { address?: string; buint?: string } };
    initialRedeemAdmin?: string;
  };
  const address = deploy.contracts?.BuintRedeemAirdrop?.address;
  const buint = deploy.contracts?.BuintRedeemAirdrop?.buint;
  const initialRedeemAdmin = deploy.initialRedeemAdmin;
  if (!address || !buint || !initialRedeemAdmin) {
    throw new Error("conet-BuintRedeemAirdrop.json 缺少 address / buint / initialRedeemAdmin");
  }

  const addr = getAddress(address);
  if (await checkVerified(addr)) {
    console.log(`⏭️ 已验证: ${BLOCKSCOUT_UI}/address/${addr}#code`);
    return;
  }

  const { standardJson, sourceCount } = exportBasescanStandardJsonFromRoot(
    root,
    "project/src/b-unit/BuintRedeemAirdrop.sol"
  );
  const standardJsonStr = JSON.stringify(standardJson);
  const ctor = AbiCoder.defaultAbiCoder()
    .encode(["address", "address"], [getAddress(buint), getAddress(initialRedeemAdmin)])
    .slice(2);

  console.log("地址:", addr);
  console.log("sources:", sourceCount);
  console.log("standard JSON bytes:", standardJsonStr.length);

  const url = `${BLOCKSCOUT_API}/v2/smart-contracts/${addr}/verification/via/standard-input`;
  const form = new FormData();
  form.set("compiler_version", COMPILER_VERSION);
  form.set("contract_name", "project/src/b-unit/BuintRedeemAirdrop.sol:BuintRedeemAirdrop");
  form.set("autodetect_constructor_args", "false");
  form.set("constructor_args", ctor);
  form.set("license_type", "mit");
  form.append("files[0]", new Blob([standardJsonStr], { type: "application/json" }), "standard-input.json");

  const res = await fetch(url, { method: "POST", body: form });
  const text = await res.text();
  console.log("HTTP:", res.status, text.slice(0, 500));

  if (!res.ok || !/verification started|already verified/i.test(text)) {
    throw new Error("验证提交失败");
  }

  for (let i = 0; i < 40; i++) {
    if (await checkVerified(addr)) {
      console.log(`✅ 验证成功: ${BLOCKSCOUT_UI}/address/${addr}#code`);
      return;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.warn("⚠️ 轮询超时，请在 Explorer 手动查看");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
