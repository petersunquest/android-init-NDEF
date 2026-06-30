/**
 * GBToken 部署后配置 / admin 运维助手（同一脚本可在 conet / base 等任意 L1 运行）。
 *
 * 运行示例:
 *   # 加入跨链 bridge validators（逗号分隔）
 *   GB_ACTION=add-validators GB_VALIDATORS=0xaaa...,0xbbb...,0xccc... \
 *     npx hardhat run scripts/configureGBToken.ts --network conet
 *
 *   # admin 空投：GB_AIRDROP_JSON 指向 [{ "to": "0x..", "gb": "12.5" }, ...]（gb 为人类可读 GB，自动 *1e9）
 *   GB_ACTION=airdrop GB_AIRDROP_JSON=./gb-airdrop.json \
 *     npx hardhat run scripts/configureGBToken.ts --network base
 *
 *   # 暂停 / 恢复跨链桥
 *   GB_ACTION=pause GB_PAUSED=false npx hardhat run scripts/configureGBToken.ts --network conet
 *
 *   # 查询状态
 *   GB_ACTION=status npx hardhat run scripts/configureGBToken.ts --network conet
 *
 * 环境变量:
 *   GB_TOKEN     覆盖 GBToken 地址（默认 GBTOKEN_CREATE2_PREDICTED）
 *   GB_ACTION    add-validators | remove-validators | add-admin | airdrop | pause | status
 */
import { network as networkModule } from "hardhat";
import * as fs from "fs";
import { getAddress, parseUnits } from "ethers";
import { GBTOKEN_CREATE2_PREDICTED } from "./gbTokenDeployConstants.js";

const DECIMALS = 9;

function parseList(env?: string): string[] {
  if (!env) return [];
  return env.split(",").map((s) => getAddress(s.trim())).filter(Boolean);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const addr = getAddress(process.env.GB_TOKEN || GBTOKEN_CREATE2_PREDICTED);
  const gb = await ethers.getContractAt("GBToken", addr, signer);
  const net = await ethers.provider.getNetwork();
  const action = (process.env.GB_ACTION || "status").toLowerCase();

  console.log("GBToken:", addr, "chainId:", net.chainId.toString(), "signer:", signer.address);
  console.log("action:", action);

  if (action === "status") {
    console.log("name:", await gb.name());
    console.log("symbol:", await gb.symbol());
    console.log("decimals:", (await gb.decimals()).toString());
    console.log("totalSupply:", (await gb.totalSupply()).toString());
    console.log("validatorCount:", (await gb.validatorCount()).toString());
    console.log("requiredVotes:", (await gb.requiredVotes()).toString());
    console.log("bridgePaused:", await gb.bridgePaused());
    console.log("admins[signer]:", await gb.admins(signer.address));
    return;
  }

  if (action === "add-validators") {
    for (const v of parseList(process.env.GB_VALIDATORS)) {
      const tx = await gb.addValidator(v);
      console.log("addValidator", v, tx.hash);
      await tx.wait();
    }
  } else if (action === "remove-validators") {
    for (const v of parseList(process.env.GB_VALIDATORS)) {
      const tx = await gb.removeValidator(v);
      console.log("removeValidator", v, tx.hash);
      await tx.wait();
    }
  } else if (action === "add-admin") {
    for (const a of parseList(process.env.GB_ADMINS)) {
      const tx = await gb.addAdmin(a);
      console.log("addAdmin", a, tx.hash);
      await tx.wait();
    }
  } else if (action === "pause") {
    const paused = (process.env.GB_PAUSED || "true").toLowerCase() === "true";
    const tx = await gb.setBridgePaused(paused);
    console.log("setBridgePaused", paused, tx.hash);
    await tx.wait();
  } else if (action === "airdrop") {
    const file = process.env.GB_AIRDROP_JSON;
    if (!file) throw new Error("缺少 GB_AIRDROP_JSON");
    const rows = JSON.parse(fs.readFileSync(file, "utf-8")) as { to: string; gb: string }[];
    const recipients = rows.map((r) => getAddress(r.to));
    const amounts = rows.map((r) => parseUnits(String(r.gb), DECIMALS));
    const tx = await gb.airdrop(recipients, amounts);
    console.log("airdrop", recipients.length, "recipients tx:", tx.hash);
    await tx.wait();
  } else {
    throw new Error(`未知 GB_ACTION: ${action}`);
  }

  console.log("✅ done");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
