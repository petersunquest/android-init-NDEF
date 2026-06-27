/** 读取四个新代币实例 name/symbol（Blockscout 展示验收） */
import { network as networkModule } from "hardhat";

async function main() {
  const { ethers } = await networkModule.connect();
  const tokens: [string, string][] = [
    ["conetUsdc", "0x2975c85D8Cc8F5d263492E332A6dAa7ad11aDBdC"],
    ["wrappedConet", "0x9619eA6617fc8D7290Ee62FDAc0a9861B50fFb06"],
    ["BUint", "0xa354CC4c414568Dd14F6d63b53013f35483427f0"],
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
