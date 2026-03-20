/**
 * 检查卡 0xeA7B... 是新合约还是老合约
 * 运行：npx hardhat run scripts/checkCardVersion.ts --network base
 */
import { ethers } from "ethers";

const CARD = "0xeA7B248CFcD457c4884371c55Ae5aFb0F428c483";

const ABI = {
  VERSION: "function VERSION() view returns (uint256)",
  getRedeemStatusEx:
    "function getRedeemStatusEx(bytes32 hash, address claimer) view returns (bool active, uint128 points6, bool isPool)",
  owner: "function owner() view returns (address)",
};

async function main() {
  const provider = new ethers.JsonRpcProvider(
    process.env.BASE_RPC || "https://base-rpc.conet.network"
  );
  const card = new ethers.Contract(CARD, Object.values(ABI), provider);

  console.log("检查卡:", CARD);
  console.log("");

  // 1. VERSION
  try {
    const version = await card.VERSION();
    console.log("VERSION():", version.toString(), "(当前源码 VERSION=10)");
  } catch (e: any) {
    console.log("VERSION(): REVERT -", (e?.message ?? e).slice(0, 100));
  }

  // 2. getRedeemStatusEx（新合约才有）
  try {
    const hash = ethers.keccak256(ethers.toUtf8Bytes("test"));
    await card.getRedeemStatusEx(hash, ethers.ZeroAddress);
    console.log("getRedeemStatusEx: OK (存在)");
  } catch (e: any) {
    console.log("getRedeemStatusEx: REVERT -", (e?.message ?? e).slice(0, 100));
  }

  // 3. owner
  try {
    const owner = await card.owner();
    console.log("owner():", owner);
  } catch (e: any) {
    console.log("owner(): REVERT -", (e?.message ?? e).slice(0, 100));
  }

  // 4. 代码长度（粗略判断是否 proxy）
  const code = await provider.getCode(CARD);
  console.log("\n合约代码长度:", code.length, "字符 (0x 后)");
  if (code.length < 200) {
    console.log("  -> 可能是 minimal proxy (EIP-1167)，代码很短");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
