import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const addrPath = path.join(__dirname, "..", "deployments", "conet-addresses.json");
const addrs = JSON.parse(fs.readFileSync(addrPath, "utf-8"));
const provider = new ethers.JsonRpcProvider("https://rpc1.conet.network");
const treasury = new ethers.Contract(addrs.ConetTreasury, ["function getCreatedTokens() view returns (address[])", "function isCreatedToken(address) view returns (bool)"], provider);
async function main() {
  const tokens = await treasury.getCreatedTokens();
  console.log("Created tokens:", tokens);
  console.log("conetUsdc in list:", await treasury.isCreatedToken(addrs.conetUsdc));
}
main();
