/** 读取四个新代币实例 name/symbol（Blockscout 展示验收） */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { network as networkModule } from "hardhat";
import { BUINT_UUPS_PROXY_PREDICTED } from "./erc20UupsDeployConstants.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ADDR_JSON = path.join(__dirname, "..", "deployments", "conet-addresses.json");

function loadAddr(key: string, fallback: string): string {
  if (!fs.existsSync(ADDR_JSON)) return fallback;
  const data = JSON.parse(fs.readFileSync(ADDR_JSON, "utf-8")) as Record<string, string>;
  return data[key] || fallback;
}

async function main() {
  const { ethers } = await networkModule.connect();
  const tokens: [string, string][] = [
    ["conetUsdc", loadAddr("conetUsdc", "0x84e55A7d82aEa1243cB88b20dDde9Ba5cea0E134")],
    ["wrappedConet", "0x9619eA6617fc8D7290Ee62FDAc0a9861B50fFb06"],
    ["BUint", loadAddr("BUint", BUINT_UUPS_PROXY_PREDICTED)],
    ["ConetGB1155", "0x3Dc53e528d45225e8F38c391Cc6a72CDec435748"],
  ];
  const abi = ["function name() view returns (string)", "function symbol() view returns (string)"];
  for (const [label, addr] of tokens) {
    const c = new ethers.Contract(addr, abi, ethers.provider);
    console.log(`${label}: name="${await c.name()}" symbol="${await c.symbol()}"`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
