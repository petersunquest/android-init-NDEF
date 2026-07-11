/**
 * Allocate 136 validator nodes to ConetLabMiningPool (beneficiary) with targetNodeIp 207.90.192.71,
 * then claim on-chain so the validator listener can run generate → fundAndDepositValidators → import.
 *
 * Stake: 32 CNET/validator from ValidatorDepositRedeem balance.
 * withdrawal_credentials: ValidatorDepositRedeem (selfWithdrawalCredentials) — exit principal returns there.
 * Economic beneficiary: ConetLabMiningPool proxy.
 *
 * Run (redeem admin / deployer must be in hardhat conet accounts):
 *   npx hardhat run scripts/setupConetLabMiningPool136Validators207.ts --network conet
 *
 * After claim, on 207.90.192.71:
 *   VALIDATOR_LISTENER_HOST=207.90.192.71 VALIDATOR_NODE_IP=207.90.192.71 \
 *     ./scripts/installValidatorNodeRedeemAdminKey.sh
 *   VALIDATOR_LISTENER_HOST=207.90.192.71 VALIDATOR_NODE_IP=207.90.192.71 \
 *     ./scripts/deployValidatorRedeemListener.sh
 *
 * Env overrides:
 *   CONET_LAB_MINING_POOL          default deployments/conet-ConetLabMiningPool.json proxy
 *   CONET_VALIDATOR_DEPOSIT_REDEEM default deployments/conet-ValidatorDepositRedeem.json proxy
 *   CONET_LAB_TARGET_NODE_IP       default 207.90.192.71
 *   CONET_LAB_VALIDATOR_COUNT      default 136
 *   CONET_LAB_SKIP_CREATE          set 1 to only claim (redeem must exist)
 *   CONET_LAB_REDEEM_CODE          required when CONET_LAB_SKIP_CREATE=1
 */

import { network as networkModule } from "hardhat";
import { ethers } from "ethers";
import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const VALIDATOR_COUNT = BigInt(process.env.CONET_LAB_VALIDATOR_COUNT?.trim() || "136");
const TARGET_NODE_IP = (process.env.CONET_LAB_TARGET_NODE_IP?.trim() || "207.90.192.71").toLowerCase();
const GB_MINING_COUNT = 0n;
const SKIP_CREATE = process.env.CONET_LAB_SKIP_CREATE === "1";

function loadJsonAddr(file: string, key: string): string {
  const p = path.join(ROOT, file);
  if (!fs.existsSync(p)) throw new Error(`missing ${p}`);
  const j = JSON.parse(fs.readFileSync(p, "utf8")) as Record<string, unknown>;
  const v = j[key] ?? j.address ?? j.proxy;
  if (typeof v !== "string" || !ethers.isAddress(v)) throw new Error(`invalid address in ${p}`);
  return ethers.getAddress(v);
}

const REDEEM = process.env.CONET_VALIDATOR_DEPOSIT_REDEEM?.trim()
  ? ethers.getAddress(process.env.CONET_VALIDATOR_DEPOSIT_REDEEM.trim())
  : loadJsonAddr("deployments/conet-ValidatorDepositRedeem.json", "address");

const POOL = process.env.CONET_LAB_MINING_POOL?.trim()
  ? ethers.getAddress(process.env.CONET_LAB_MINING_POOL.trim())
  : loadJsonAddr("deployments/conet-ConetLabMiningPool.json", "address");

const ABI = [
  "function redeemAdmins(address) view returns (bool)",
  "function redeemAdminNonces(address) view returns (uint256)",
  "function nextGuardianAllocId() view returns (uint256)",
  "function guardianAllocStartId() view returns (uint256)",
  "function guardianIdBeneficiary(uint256) view returns (address)",
  "function validatorNodeCountOf(address) view returns (uint256)",
  "function selfWithdrawalCredentials() view returns (bytes32)",
  "function createRedeemFor(address admin,bytes32 codeHash,address allowedClaimer,address referrer,uint256 validatorCount,string targetNodeIp,uint256 gbMiningNodeCount,bool airdrop,uint256 validAfter,uint256 validBefore,uint256 nonce,uint256 deadline,bytes signature) external",
  "function claimRedeem(string code, address beneficiary) external returns (bytes32)",
  "function getBeneficiaryNodeBundle(address) view returns (tuple(address beneficiary,uint256[] guardianNodeIds,string[] depinNodeIps,address[] nodeWallets,bytes[] validatorPubkeys,bool[] validatorActive,uint256 validatorNodeCount,uint256 gbMiningNodeCount,uint256 claimCount,uint256 nativeBalance,uint256 gbBalance,uint256 usdcBalance))",
] as const;

async function preflightAllocation(provider: ethers.Provider, count: bigint): Promise<void> {
  const guardian = new ethers.Contract(
    "0xBC6b53065b5647261396d002bDBA0d3396E0722f",
    [
      "function id2ip(uint256 id) view returns (string)",
      "function ipaddressExisting(string ip) view returns (bool)",
      "function idOwner(uint256 id) view returns (address)",
      "function ipaddress2owner(string ip) view returns (address)",
    ],
    provider
  );
  const redeem = new ethers.Contract(REDEEM, ABI, provider);
  let nextId = (await redeem.nextGuardianAllocId!()) as bigint;
  const startId = (await redeem.guardianAllocStartId!()) as bigint;
  for (let need = 0n; need < count; need++) {
    let resolved = false;
    while (!resolved) {
      if (nextId < startId) throw new Error("Guardian allocation pool exhausted");
      const idOwner = ethers.getAddress((await redeem.guardianIdBeneficiary!(nextId)) as string);
      if (idOwner !== ethers.ZeroAddress) {
        nextId++;
        continue;
      }
      const ip = String(await guardian.id2ip!(nextId));
      if (!ip) throw new Error(`guardian id ${nextId} has no IP`);
      if (!(await guardian.ipaddressExisting!(ip))) throw new Error(`guardian IP ${ip} not registered`);
      let nodeWallet = ethers.getAddress((await guardian.idOwner!(nextId)) as string);
      if (nodeWallet === ethers.ZeroAddress) {
        nodeWallet = ethers.getAddress((await guardian.ipaddress2owner!(ip)) as string);
      }
      if (nodeWallet === ethers.ZeroAddress) throw new Error(`guardian id ${nextId} has no operator wallet`);
      resolved = true;
      nextId++;
    }
  }
}

async function main() {
  const { ethers: ethersHH } = await networkModule.connect();
  const [signer] = await ethersHH.getSigners();
  const me = ethers.getAddress(await signer.getAddress());
  const net = await ethersHH.provider.getNetwork();
  if (net.chainId !== 224422n) throw new Error(`expected chain 224422, got ${net.chainId}`);

  const c = new ethers.Contract(REDEEM, ABI, signer);
  if (!(await c.redeemAdmins!(me))) throw new Error(`${me} is not redeemAdmin on ${REDEEM}`);

  const needWei = 32n * 10n ** 18n * VALIDATOR_COUNT;
  const bal = await ethersHH.provider.getBalance(REDEEM);
  if (bal < needWei) {
    throw new Error(
      `ValidatorDepositRedeem balance ${ethers.formatEther(bal)} CNET < ${ethers.formatEther(needWei)} needed for ${VALIDATOR_COUNT} validators`
    );
  }

  const selfCred = await c.selfWithdrawalCredentials!();
  console.log("ValidatorDepositRedeem:", REDEEM);
  console.log("ConetLabMiningPool (beneficiary):", POOL);
  console.log("targetNodeIp:", TARGET_NODE_IP);
  console.log("validatorCount:", VALIDATOR_COUNT.toString());
  console.log("selfWithdrawalCredentials (exit principal → Redeem):", selfCred);
  console.log("redeem contract balance:", ethers.formatEther(bal), "CNET");

  await preflightAllocation(ethersHH.provider, VALIDATOR_COUNT);
  console.log("allocation preflight: OK (next ids from", (await c.nextGuardianAllocId!()).toString(), ")");

  let redeemCode = process.env.CONET_LAB_REDEEM_CODE?.trim() || "";

  if (!SKIP_CREATE) {
    redeemCode = `conetlab-mining-pool-136-${TARGET_NODE_IP.replace(/\./g, "-")}-${Date.now()}`;
    const codeHash = ethers.keccak256(ethers.toUtf8Bytes(redeemCode));
    const nonce = await c.redeemAdminNonces!(me);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 7 * 24 * 3600);
    const domain = { name: "ValidatorDepositRedeem", version: "1", chainId: 224422, verifyingContract: REDEEM };
    const types = {
      CreateRedeem: [
        { name: "admin", type: "address" },
        { name: "codeHash", type: "bytes32" },
        { name: "allowedClaimer", type: "address" },
        { name: "referrer", type: "address" },
        { name: "validatorCount", type: "uint256" },
        { name: "targetNodeIp", type: "string" },
        { name: "gbMiningNodeCount", type: "uint256" },
        { name: "airdrop", type: "bool" },
        { name: "validAfter", type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };
    const value = {
      admin: me,
      codeHash,
      allowedClaimer: me,
      referrer: ethers.ZeroAddress,
      validatorCount: VALIDATOR_COUNT,
      targetNodeIp: TARGET_NODE_IP,
      gbMiningNodeCount: GB_MINING_COUNT,
      airdrop: false,
      validAfter: 0n,
      validBefore: 0n,
      nonce,
      deadline,
    };
    const sig = await signer.signTypedData(domain, types, value);
    const gasCreate = await c.createRedeemFor!.estimateGas(
      me,
      codeHash,
      me,
      ethers.ZeroAddress,
      VALIDATOR_COUNT,
      TARGET_NODE_IP,
      GB_MINING_COUNT,
      false,
      0n,
      0n,
      nonce,
      deadline,
      sig
    );
    const txC = await c.createRedeemFor!(
      me,
      codeHash,
      me,
      ethers.ZeroAddress,
      VALIDATOR_COUNT,
      TARGET_NODE_IP,
      GB_MINING_COUNT,
      false,
      0n,
      0n,
      nonce,
      deadline,
      sig,
      { gasLimit: (gasCreate * 120n) / 100n }
    );
    const rcC = await txC.wait();
    console.log("createRedeemFor tx:", rcC?.hash ?? txC.hash);
  } else if (!redeemCode) {
    throw new Error("CONET_LAB_REDEEM_CODE required when CONET_LAB_SKIP_CREATE=1");
  }

  const existingCount = await c.validatorNodeCountOf!(POOL);
  if (existingCount >= VALIDATOR_COUNT) {
    console.log(`beneficiary already has ${existingCount} validator nodes (>= ${VALIDATOR_COUNT}); skip claim`);
  } else {
    const gasClaim = await c.claimRedeem!.estimateGas(redeemCode, POOL);
    const txClaim = await c.claimRedeem!(redeemCode, POOL, {
      gasLimit: (gasClaim * 120n) / 100n,
    });
    const rcClaim = await txClaim.wait();
    console.log("claimRedeem tx:", rcClaim?.hash ?? txClaim.hash);
  }

  const bundle = await c.getBeneficiaryNodeBundle!(POOL);
  const outPath = path.join(ROOT, "deployments/conet-ConetLabMiningPool-136validators-207.json");
  const record = {
    beneficiary: POOL,
    validatorDepositRedeem: REDEEM,
    targetNodeIp: TARGET_NODE_IP,
    validatorCount: Number(VALIDATOR_COUNT),
    redeemCode: redeemCode,
    selfWithdrawalCredentials: selfCred,
    guardianNodeIds: bundle.guardianNodeIds.map((x: bigint) => x.toString()),
    depinNodeIps: bundle.depinNodeIps,
    validatorNodeCountOnChain: bundle.validatorNodeCount.toString(),
    timestamp: new Date().toISOString(),
    nextSteps: [
      "VALIDATOR_LISTENER_HOST=207.90.192.71 ./scripts/installValidatorNodeRedeemAdminKey.sh",
      "VALIDATOR_LISTENER_HOST=207.90.192.71 VALIDATOR_NODE_IP=207.90.192.71 ./scripts/deployValidatorRedeemListener.sh",
      "Listener runs generate → fundAndDepositValidators → 08_import; fee_recipient → ConetLabMiningPool",
    ],
  };
  fs.writeFileSync(outPath, JSON.stringify(record, null, 2) + "\n");
  console.log("wrote", outPath);
  console.log("guardian ids:", record.guardianNodeIds.slice(0, 5).join(", "), "... total", record.guardianNodeIds.length);
  console.log("REDEEM_CODE (save securely):", redeemCode);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
