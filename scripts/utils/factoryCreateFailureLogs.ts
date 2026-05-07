/**
 * Decode BeamioUserCardFactoryPaymasterV07 failure events from a tx receipt.
 */
const FACTORY_FAILURE_EVENTS_ABI = [
  "event DeployFailedStep(uint8 step)",
  "event DeployFailedCreateDebug(uint256 initCodeLength, bytes32 initCodeHash)",
  "event CardDeployed(address indexed cardOwner, address indexed card, uint8 currency, uint256 priceE18)",
];

export function printFactoryCreateFailureLogs(
  ethers: { Interface: typeof import("ethers").Interface },
  factoryAddr: string,
  receipt: { logs: readonly { address: string; topics: readonly string[]; data: string }[] },
): void {
  const fa = factoryAddr.toLowerCase();
  const iface = new ethers.Interface(FACTORY_FAILURE_EVENTS_ABI);
  console.log("\n--- Factory failure / deploy debug logs ---");
  let any = false;
  for (const log of receipt.logs ?? []) {
    if (log.address.toLowerCase() !== fa) continue;
    try {
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      any = true;
      const name = parsed?.name;
      const args = parsed?.args;
      if (name === "DeployFailedCreateDebug" && args) {
        console.log(name, {
          initCodeLength: args[0]?.toString?.() ?? args[0],
          initCodeHash: args[1],
        });
      } else if (name === "DeployFailedStep" && args) {
        console.log(name, { step: args[0]?.toString?.() ?? args[0] });
      } else {
        console.log(name, args);
      }
    } catch {
      /* not these events */
    }
  }
  if (!any) {
    console.log(
      "(no DeployFailedStep / DeployFailedCreateDebug from this factory in receipt — production bytecode may predate these events)",
    );
  }
}
