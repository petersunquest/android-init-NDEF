/**
 * 在 CoNET (224422) 上调用 LayerMinusNodeRestart_V2.setRestart()。
 * 仅 adminList 中的地址可成功；构造函数已将部署者设为 admin。
 *
 * 运行: npx hardhat run scripts/callLayerMinusNodeRestartSetRestart.ts --network conet
 *
 * 环境变量:
 *   LAYERMINUS_RESTART_V2_ADDRESS — 合约地址（默认读 deployments）
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.join(__dirname, "..");

function resolveAddress(): string {
  const env = process.env.LAYERMINUS_RESTART_V2_ADDRESS?.trim();
  if (env) return env;
  const depJson = path.join(root, "deployments", "conet-LayerMinusNodeRestart_V2.json");
  if (fs.existsSync(depJson)) {
    const j = JSON.parse(fs.readFileSync(depJson, "utf-8")) as { address?: string };
    if (j.address) return j.address;
  }
  const addrJson = path.join(root, "deployments", "conet-addresses.json");
  if (fs.existsSync(addrJson)) {
    const j = JSON.parse(fs.readFileSync(addrJson, "utf-8")) as { LayerMinusNodeRestart_V2?: string };
    if (j.LayerMinusNodeRestart_V2) return j.LayerMinusNodeRestart_V2;
  }
  throw new Error("无法解析合约地址：设置 LAYERMINUS_RESTART_V2_ADDRESS 或保留 deployments 记录");
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) {
    throw new Error("无签名账户：请配置 ~/.master.json（conet 网络）或 PRIVATE_KEY");
  }
  const net = await ethers.provider.getNetwork();
  if (net.chainId !== 224422n) {
    throw new Error(`期望 chainId 224422，当前 ${net.chainId}`);
  }

  const address = resolveAddress();
  console.log("合约:", address);
  console.log("signer:", signer.address);

  const c = await ethers.getContractAt("LayerMinusNodeRestart_V2", address, signer);
  const before = await c.restartBlockNumber();
  console.log("restartBlockNumber (before):", before.toString());

  const tx = await c.setRestart();
  console.log("tx:", tx.hash);
  const receipt = await tx.wait();
  console.log("confirmed in block:", receipt?.blockNumber);

  const after = await c.restartBlockNumber();
  console.log("restartBlockNumber (after):", after.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
