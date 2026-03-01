/**
 * 通过链上时间确认哪个是“新”Card Factory：比较两地址的合约创建区块时间。
 * 0x19C... = 当前 config/deployments 使用的地址；0x7Ec82... = 脚本/README 中曾出现的旧默认值。
 *
 * 运行：npx hardhat run scripts/verifyCardFactoryAgeOnChain.ts --network base
 */
import { network as networkModule } from "hardhat";

const ADDR_CURRENT = "0xDdD5c17E549a4e66ca636a3c528ae8FAebb8692b";
const ADDR_OLD_DEFAULT = "0x7Ec828BAbA1c58C5021a6E7D29ccDDdB2d8D84bd";
const DEPLOY_TX_CURRENT = "0x3f34e13c6ba8fac1d9bcd488732fbdab3c3c59cc1859d3bcd9eee4d6cebc8680";

async function main() {
  const { ethers } = await networkModule.connect();
  const provider = ethers.provider;

  console.log("========== 链上 Card Factory 创建时间对比 ==========\n");

  // 1) 当前使用的 0x19C...：用已知部署交易取区块时间
  let blockNumCurrent: number;
  let timestampCurrent: number;
  try {
    const tx = await provider.getTransaction(DEPLOY_TX_CURRENT);
    if (!tx || !tx.blockNumber) {
      throw new Error("部署交易不存在或未上链");
    }
    blockNumCurrent = tx.blockNumber;
    const block = await provider.getBlock(blockNumCurrent);
    if (!block) throw new Error("区块不存在");
    timestampCurrent = block.timestamp;
    console.log("当前 config 使用的 Factory:", ADDR_CURRENT);
    console.log("  部署 tx:", DEPLOY_TX_CURRENT);
    console.log("  区块:", blockNumCurrent, "时间戳:", timestampCurrent, "(", new Date(timestampCurrent * 1000).toISOString(), ")");
  } catch (e) {
    console.error("获取 0x19C... 部署时间失败:", (e as Error).message);
    process.exit(1);
  }

  // 2) 旧默认值 0x7Ec82...：Basescan API 获取创建信息（可选）；若无 API 则用二分查找首次出现 code 的区块
  const apiKey = process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY || "";
  let blockNumOld: number;
  let timestampOld: number;

  if (apiKey) {
    try {
      const url = `https://api.basescan.org/api?module=contract&action=getcontractcreation&contractaddresses=${ADDR_OLD_DEFAULT}&apikey=${apiKey}`;
      const res = await fetch(url);
      const data = await res.json();
      if (data.status !== "1" || !data.result?.length) {
        throw new Error(data.message || "API 未返回创建信息");
      }
      const r = data.result[0];
      blockNumOld = parseInt(r.blockNumber, 10);
      timestampOld = parseInt(r.timeStamp, 10);
      console.log("\n旧默认 Factory:", ADDR_OLD_DEFAULT);
      console.log("  创建区块:", blockNumOld, "时间戳:", timestampOld, "(", new Date(timestampOld * 1000).toISOString(), ")");
    } catch (e) {
      console.warn("Basescan API 获取 0x7Ec82... 失败，改用二分查找:", (e as Error).message);
      const result = await findCreationBlockByBisect(provider, ADDR_OLD_DEFAULT);
      blockNumOld = result.blockNumber;
      timestampOld = result.timestamp;
      console.log("\n旧默认 Factory:", ADDR_OLD_DEFAULT);
      console.log("  首次出现 code 的区块:", blockNumOld, "时间戳:", timestampOld, "(", new Date(timestampOld * 1000).toISOString(), ")");
    }
  } else {
    const result = await findCreationBlockByBisect(provider, ADDR_OLD_DEFAULT);
    blockNumOld = result.blockNumber;
    timestampOld = result.timestamp;
    console.log("\n旧默认 Factory:", ADDR_OLD_DEFAULT);
    console.log("  首次出现 code 的区块:", blockNumOld, "时间戳:", timestampOld, "(", new Date(timestampOld * 1000).toISOString(), ")");
  }

  // 3) 比较
  console.log("\n---------- 结论 ----------");
  if (timestampCurrent > timestampOld) {
    console.log("当前 config 使用的 0x19C... 创建时间晚于 0x7Ec82...");
    console.log("=> 0x19C... 是较新的 Factory，替换为 0x19C... 正确。");
  } else if (timestampCurrent < timestampOld) {
    console.log("当前 config 使用的 0x19C... 创建时间早于 0x7Ec82...");
    console.log("=> 0x7Ec82... 才是较新的 Factory，需要改回 0x7Ec82...。");
  } else {
    console.log("两者创建时间相同（或无法区分）。");
  }
  console.log("================================");
}

/** 二分查找合约首次出现 code 的区块（仅用 RPC） */
async function findCreationBlockByBisect(
  provider: { getCode: (addr: string, block?: string | number) => Promise<string>; getBlock: (block: number | string) => Promise<{ timestamp: number; number: number } | null> },
  address: string
): Promise<{ blockNumber: number; timestamp: number }> {
  const latestBlock = (await provider.getBlock("latest"))!.number;
  const codeNow = await provider.getCode(address, latestBlock);
  if (!codeNow || codeNow === "0x") {
    throw new Error("该地址在当前链上无合约代码，可能未部署或已销毁");
  }
  let lo = 0;
  let hi = latestBlock;
  while (lo + 1 < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const code = await provider.getCode(address, mid);
    if (code && code !== "0x") hi = mid;
    else lo = mid;
  }
  const codeLo = await provider.getCode(address, lo);
  const blockNum = codeLo && codeLo !== "0x" ? lo : hi;
  const block = await provider.getBlock(blockNum);
  if (!block) throw new Error("区块不存在");
  return { blockNumber: blockNum, timestamp: block.timestamp };
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
