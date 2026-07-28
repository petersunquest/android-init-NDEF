import * as fs from "fs";
import { homedir } from "os";
import path from "path";

/**
 * 与 deployFactoryAndModule / deployUserCardFactory 一致：
 * 优先 PRIVATE_KEY，否则 ~/.master.json settle_contractAdmin[0]
 */
export function loadSignerPk(): string {
  if (process.env.PRIVATE_KEY?.trim()) {
    const pk = process.env.PRIVATE_KEY.trim();
    return pk.startsWith("0x") ? pk : `0x${pk}`;
  }
  const setupPath = path.join(homedir(), ".master.json");
  if (!fs.existsSync(setupPath)) {
    throw new Error("未找到 PRIVATE_KEY，且 ~/.master.json 不存在");
  }
  const data = JSON.parse(fs.readFileSync(setupPath, "utf-8"));
  const pk = data?.settle_contractAdmin?.[0];
  if (!pk || typeof pk !== "string") {
    throw new Error("未找到 PRIVATE_KEY，且 ~/.master.json 缺少 settle_contractAdmin[0]");
  }
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}
