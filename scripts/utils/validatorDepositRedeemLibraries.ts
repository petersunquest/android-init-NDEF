import type { HardhatEthers } from "@nomicfoundation/hardhat-ethers/types";

export const VALIDATOR_DEPOSIT_REDEEM_LIBRARY_NAMES = [
  "ValidatorDepositRedeemStatsLib",
  "ValidatorDepositRedeemRewardLib",
  "ValidatorDepositRedeemBundleLib",
  "ValidatorDepositRedeemTransferLib",
  "ValidatorDepositRedeemDepositLib",
  "ValidatorDepositRedeemExitLib",
  "ValidatorDepositRedeemReleaseLib",
  "ValidatorDepositRedeemAllocLib",
] as const;

export type ValidatorDepositRedeemLibraryName = (typeof VALIDATOR_DEPOSIT_REDEEM_LIBRARY_NAMES)[number];

export type ValidatorDepositRedeemLibraryLinks = Record<ValidatorDepositRedeemLibraryName, string>;

/** Deploy all linked external libraries for ValidatorDepositRedeem (UUPS implementation). */
export async function deployValidatorDepositRedeemLibraries(
  ethersHH: HardhatEthers
): Promise<ValidatorDepositRedeemLibraryLinks> {
  const links = {} as ValidatorDepositRedeemLibraryLinks;
  for (const name of VALIDATOR_DEPOSIT_REDEEM_LIBRARY_NAMES) {
    const Factory = await ethersHH.getContractFactory(name);
    const lib = await Factory.deploy();
    await lib.waitForDeployment();
    links[name] = await lib.getAddress();
    console.log(`${name}:`, links[name]);
  }
  return links;
}

export function libraryLinksFromDeployJson(raw: unknown): Partial<ValidatorDepositRedeemLibraryLinks> {
  if (!raw || typeof raw !== "object") return {};
  const d = raw as {
    libraryLinks?: Partial<ValidatorDepositRedeemLibraryLinks>;
    statsLib?: string;
    contracts?: Record<string, { address?: string }>;
  };
  const out: Partial<ValidatorDepositRedeemLibraryLinks> = { ...(d.libraryLinks ?? {}) };
  if (d.statsLib && !out.ValidatorDepositRedeemStatsLib) {
    out.ValidatorDepositRedeemStatsLib = d.statsLib;
  }
  if (d.contracts) {
    for (const name of VALIDATOR_DEPOSIT_REDEEM_LIBRARY_NAMES) {
      const addr = d.contracts[name]?.address;
      if (addr && !out[name]) out[name] = addr;
    }
  }
  return out;
}
