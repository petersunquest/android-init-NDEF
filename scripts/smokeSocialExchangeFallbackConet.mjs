#!/usr/bin/env node
import { network } from "hardhat";

const FACTORY = "0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB";
const ADMIN_STATS = "0x68F16862373BE916E68aCFF3049E6Bd6eaF74921";
const SMOKE_CARD = "0xB24D242A320b8dd756572b410645FE41Cd07FC8C";

const { ethers } = await network.connect();
const provider = ethers.provider;

const factory = new ethers.Contract(FACTORY, [
  "function defaultIssuedNftModule() view returns (address)",
  "function defaultChargeRewardModule() view returns (address)",
  "function defaultAdminStatsQueryModule() view returns (address)",
], provider);

const admin = new ethers.Contract(ADMIN_STATS, [
  "function selectorModuleKind(bytes4) view returns (uint8)",
], provider);

const claimSel = ethers.id(
  "claimSocialExchangeWithUserSignature(address,uint256,uint256,uint256,uint256,bytes32,bytes)",
).slice(0, 10);

const cardCode = await provider.getCode(SMOKE_CARD);
const issuedAddr = await factory.defaultIssuedNftModule();
const issuedCode = await provider.getCode(issuedAddr);

console.log("Factory modules:", {
  issuedNft: issuedAddr,
  chargeReward: await factory.defaultChargeRewardModule(),
  adminStats: await factory.defaultAdminStatsQueryModule(),
});
console.log("AdminStats claimSocialExchange route kind:", await admin.selectorModuleKind(claimSel));
console.log("Smoke card native claim selector:", cardCode.toLowerCase().includes(claimSel.slice(2).toLowerCase()));
console.log("IssuedNft module has claim selector:", issuedCode.toLowerCase().includes(claimSel.slice(2).toLowerCase()));
