/**
 * 本地检查卡 0xB7644DDb12656F4854dC746464af47D33C206F0E
 * 运行：npx hardhat run scripts/checkCard0xB7644DDb.ts --network base
 */
import { ethers } from "ethers";

const CARD = "0xB7644DDb12656F4854dC746464af47D33C206F0E";
const CARD_FACTORY = "0xDdD5c17E549a4e66ca636a3c528ae8FAebb8692b";

const ABI = {
  owner: "function owner() view returns (address)",
  factoryGateway: "function factoryGateway() view returns (address)",
  VERSION: "function VERSION() view returns (uint256)",
  adminList: "function adminList(uint256) view returns (address)",
  isAdmin: "function isAdmin(address) view returns (bool)",
  addAdmin: "function addAdmin(address newAdmin, uint256 newThreshold)",
};

async function main() {
  const provider = new ethers.JsonRpcProvider(
    process.env.BASE_RPC_URL || process.env.BASE_RPC || "https://base-rpc.conet.network"
  );
  const card = new ethers.Contract(CARD, Object.values(ABI), provider);

  console.log("=== 检查卡:", CARD, "===\n");

  // 1. 合约代码
  const code = await provider.getCode(CARD);
  console.log("1. 合约代码长度:", code.length, "字符 (0x 后)");
  if (code.length <= 4) {
    console.log("   ❌ 无代码，地址可能未部署");
    return;
  }

  // 2. owner
  try {
    const owner = await card.owner();
    console.log("2. owner():", owner);
  } catch (e: any) {
    console.log("2. owner(): REVERT -", (e?.message ?? e).slice(0, 120));
  }

  // 3. factoryGateway（关键：必须等于 CARD_FACTORY 才能 executeForOwner）
  try {
    const gw = await card.factoryGateway();
    console.log("3. factoryGateway():", gw);
    const match = gw.toLowerCase() === CARD_FACTORY.toLowerCase();
    console.log("   与 CARD_FACTORY 一致?", match ? "✅ 是" : "❌ 否");
  } catch (e: any) {
    console.log("3. factoryGateway(): REVERT -", (e?.message ?? e).slice(0, 120));
  }

  // 4. VERSION
  try {
    const version = await card.VERSION();
    console.log("4. VERSION():", version.toString());
  } catch (e: any) {
    console.log("4. VERSION(): REVERT -", (e?.message ?? e).slice(0, 120));
  }

  // 5. adminList
  try {
    const admin0 = await card.adminList(0);
    console.log("5. adminList(0):", admin0);
  } catch (e: any) {
    console.log("5. adminList(0): REVERT -", (e?.message ?? e).slice(0, 120));
  }

  // 6. addAdmin 选择器是否存在（通过 staticCall 模拟，不实际执行）
  const iface = new ethers.Interface(["function addAdmin(address newAdmin, uint256 newThreshold)"]);
  const calldata = iface.encodeFunctionData("addAdmin", [ethers.ZeroAddress, 1]);
  try {
    await provider.call({ to: CARD, data: calldata });
    console.log("6. addAdmin(0x0,1) staticCall: 未 revert（但实际执行可能因 BM_ZeroAddress 等失败）");
  } catch (e: any) {
    const msg = e?.message ?? String(e);
    console.log("6. addAdmin(0x0,1) staticCall: REVERT");
    console.log("   原因:", msg.slice(0, 200));
    if (msg.includes("0x36550849") || msg.includes("BM_CallFailed")) {
      console.log("   -> BM_CallFailed: 调用失败且无 revert 数据");
    }
  }

  console.log("\n=== 检查完成 ===");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
