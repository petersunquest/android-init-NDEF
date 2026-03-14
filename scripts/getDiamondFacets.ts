/** 从链上获取 Diamond 的 facet 地址并映射到合约名 */
import { ethers } from "ethers";

const DIAMOND = "0x9d481CC9Da04456e98aE2FD6eB6F18e37bf72eb5";
const RPC = "https://mainnet-rpc.conet.network";

const LOUPE_ABI = [
  "function facets() view returns (tuple(address facetAddress, bytes4[] functionSelectors)[])",
  "function facetAddress(bytes4 selector) view returns (address)",
];

// 已知 selector -> 合约名
const SELECTOR_TO_NAME: Record<string, string> = {
  [ethers.id("diamondCut((address,uint8,bytes4[])[],address,bytes)").slice(0, 10)]: "DiamondCutFacet",
  [ethers.id("facets()").slice(0, 10)]: "DiamondLoupeFacet",
  [ethers.id("owner()").slice(0, 10)]: "OwnershipFacet",
  [ethers.id("isAdmin(address)").slice(0, 10)]: "AdminFacet",
  [ethers.id("getActionCount()").slice(0, 10)]: "ActionFacet",
  [ethers.id("registerCard((address,address,string,string,string,uint8,uint256,uint8,uint64,uint64,bool))").slice(0, 10)]: "CatalogFacet",
  [ethers.id("getAggregatedStats()").slice(0, 10)]: "StatsFacet",
  [ethers.id("getTaskCount()").slice(0, 10)]: "TaskFacet",
  [ethers.id("getBeamioUserCardTokenHolderCount(address,uint256)").slice(0, 10)]: "BeamioUserCardStatsFacet",
  [ethers.id("getBServiceUnits6ByCurrentPeriodOffsetHour(address,int256,uint8,uint8,uint16,uint256)").slice(0, 10)]: "FeeStatsFacet",
};

async function main() {
  const p = new ethers.JsonRpcProvider(RPC);
  const loupe = new ethers.Contract(DIAMOND, LOUPE_ABI, p);
  const rawFacets = await loupe.facets();

  const addrToName = new Map<string, string>();
  for (const f of rawFacets) {
    for (const sel of f.functionSelectors) {
      const name = SELECTOR_TO_NAME[sel];
      if (name) {
        addrToName.set(f.facetAddress.toLowerCase(), name);
        break;
      }
    }
  }

  const known = new Set(addrToName.values());
  const allNames = [
    "DiamondCutFacet",
    "DiamondLoupeFacet",
    "OwnershipFacet",
    "AdminFacet",
    "ActionFacet",
    "CatalogFacet",
    "StatsFacet",
    "TaskFacet",
    "BeamioUserCardStatsFacet",
    "FeeStatsFacet",
  ];
  const remainder = allNames.filter((n) => !known.has(n));

  console.log("映射结果 (address -> contractName):");
  const result: { address: string; name: string }[] = [];
  for (const f of rawFacets) {
    const name = addrToName.get(f.facetAddress.toLowerCase()) || remainder.shift() || "Unknown";
    result.push({ address: f.facetAddress, name });
    console.log(f.facetAddress, name, f.functionSelectors.length);
  }
  console.log("\nJSON for script:");
  console.log(JSON.stringify(result, null, 2));
}

main();
