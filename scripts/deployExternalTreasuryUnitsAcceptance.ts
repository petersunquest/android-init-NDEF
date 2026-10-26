import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Deploys ExternalTreasuryUnits with its test mocks, then runs the acceptance flow on it:
 * three deposits, activation of each deposit's unit, and three withdrawals.
 *
 * The proof contracts are test mocks operated by the deployer. Their proofs do not come from CoNET,
 * so the withdrawals check on-chain unit selection and accounting, not the cross-chain burn.
 *
 * Run: npx hardhat run scripts/deployExternalTreasuryUnitsAcceptance.ts --network baseSepolia
 * Writes deployments/baseSepolia-ExternalTreasuryUnits.json only on Base Sepolia (chain 84532).
 */

const ONE_USDC = 1_000_000n; // 6 decimals
const CAP = 1_000n * ONE_USDC; // per-deposit cap set at deployment
const MAX_PROOF_AGE = 2_000n; // blocks; a testnet value (about 67 minutes at 2-second blocks)
const BASE_SEPOLIA_CHAIN_ID = 84532n;
const LOCAL_CHAIN_ID = 31337n;

const DEPOSIT_AMOUNTS = [100n * ONE_USDC, 50n * ONE_USDC, 80n * ONE_USDC];
const WITHDRAWAL_AMOUNTS = [120n * ONE_USDC, 30n * ONE_USDC, 50n * ONE_USDC];
const UNIT_STATUS = ["NONE", "REGISTERED", "ACTIVE", "RESTRICTED", "RECON_PENDING", "SPENT", "LOSS_CONFIRMED"];

function sum(values: bigint[]): bigint {
  return values.reduce((total, value) => total + value, 0n);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  const { chainId } = await ethers.provider.getNetwork();

  // Refuse to run anywhere except the in-process network or Base Sepolia, so a stray --network flag cannot reach mainnet.
  if (chainId !== BASE_SEPOLIA_CHAIN_ID && chainId !== LOCAL_CHAIN_ID) {
    throw new Error(`Refusing to run on chain ${chainId}; use --network baseSepolia`);
  }

  console.log("=".repeat(60));
  console.log("ExternalTreasuryUnits: deploy and acceptance");
  console.log("=".repeat(60));
  console.log("chainId:", chainId.toString());
  console.log("deployer:", deployer.address);
  const deployerBalance = await ethers.provider.getBalance(deployer.address);
  console.log("balance:", ethers.formatEther(deployerBalance), "ETH");
  if (chainId === BASE_SEPOLIA_CHAIN_ID && deployerBalance < ethers.parseEther("0.01")) {
    throw new Error("Deployer holds less than 0.01 Base Sepolia ETH; fund it before deploying");
  }

  const contracts: Record<string, { address: string; txHash: string }> = {};

  async function deployContract(name: string, args: unknown[] = []): Promise<any> {
    const contract = await (await ethers.getContractFactory(name)).deploy(...args);
    await contract.waitForDeployment();
    const address = await contract.getAddress();
    const txHash = contract.deploymentTransaction()?.hash ?? "";
    contracts[name] = { address, txHash };
    console.log(`deployed ${name}: ${address} (tx ${txHash})`);
    return contract;
  }

  async function send(label: string, pending: Promise<any>): Promise<any> {
    const receipt = await (await pending).wait();
    console.log(`${label}: ${receipt.hash} (block ${receipt.blockNumber})`);
    return receipt;
  }

  // 1. Deploy
  const verifier = await deployContract("ExternalTreasuryMockVerifier");
  const stateVerifier = await deployContract("UnitStateMockVerifier");
  const implementation = await deployContract("DepositUnit");
  const usdc = await deployContract("DepositUnitMockUSDC");
  const treasury = await deployContract("ExternalTreasuryUnits", [
    await verifier.getAddress(),
    await stateVerifier.getAddress(),
    await implementation.getAddress(),
    MAX_PROOF_AGE,
    [await usdc.getAddress()],
    [CAP],
  ]);
  const verifierAddress = await verifier.getAddress();
  const stateVerifierAddress = await stateVerifier.getAddress();
  const usdcAddress = await usdc.getAddress();
  const treasuryAddress = await treasury.getAddress();
  const factoryAddress = await treasury.FACTORY();
  contracts.DepositUnitFactory = {
    address: factoryAddress,
    txHash: contracts.ExternalTreasuryUnits.txHash, // created inside the treasury constructor
  };

  const acceptance: Record<string, any> = { deposits: [], activations: [], withdrawals: [] };

  // 2. Fund the deployer with test USDC and approve the treasury
  const total = sum(DEPOSIT_AMOUNTS);
  const mintReceipt = await send("mint test USDC to deployer", usdc.mint(deployer.address, total));
  const approveReceipt = await send("approve treasury", usdc.approve(treasuryAddress, total));
  acceptance.mint = { txHash: mintReceipt.hash };
  acceptance.approve = { txHash: approveReceipt.hash };

  // 3. Deposits: each one derives its own unit and transfers the tokens straight into it
  for (const [i, amount] of DEPOSIT_AMOUNTS.entries()) {
    const commitment = ethers.id(`conet-beneficiary-${i + 1}`);
    const receipt = await send(
      `deposit ${i + 1} (${ethers.formatUnits(amount, 6)} USDC)`,
      treasury.deposit(usdcAddress, amount, commitment),
    );
    const event = receipt.logs
      .map((log: any) => treasury.interface.parseLog(log))
      .find((parsed: any) => parsed?.name === "Deposited");
    const depositId = event.args.depositId as string;
    const unit = (await treasury.unitOf(depositId)) as string;
    acceptance.deposits.push({
      index: i + 1,
      amount: amount.toString(),
      commitment,
      depositId,
      unit,
      txHash: receipt.hash,
      blockNumber: receipt.blockNumber,
    });
  }

  // 4. Activate each unit with a state proof (a mock proof, registered by the deployer)
  for (const d of acceptance.deposits) {
    const record = await treasury.units(d.unit);
    const balance = await usdc.balanceOf(d.unit);
    const head = BigInt(await ethers.provider.getBlockNumber());
    const last = BigInt(record.lastProofBlock);
    const proofBlock = (head > last ? head : last) + 1n;
    const proof = ethers.hexlify(ethers.randomBytes(32));
    const registerReceipt = await send(
      `state proof for unit ${d.index} (block ${proofBlock})`,
      stateVerifier.registerUnitState(proof, {
        chainId,
        treasury: treasuryAddress,
        unit: d.unit,
        token: usdcAddress,
        restricted: false,
        balance,
        blockNumber: proofBlock,
      }),
    );
    const reportReceipt = await send(`report unit ${d.index} active`, treasury.reportUnitState(proof));
    const status = UNIT_STATUS[Number((await treasury.units(d.unit)).status)];
    acceptance.activations.push({
      unit: d.unit,
      proofBlock: proofBlock.toString(),
      registerTxHash: registerReceipt.hash,
      reportTxHash: reportReceipt.hash,
      blockNumber: reportReceipt.blockNumber,
      statusAfter: status,
    });
  }

  // 5. Withdrawals: each burn proof is registered, then released in one transaction
  for (const [j, amount] of WITHDRAWAL_AMOUNTS.entries()) {
    const [selected, takes] = await treasury.previewPayment(usdcAddress, amount);
    const proof = ethers.hexlify(ethers.randomBytes(32));
    const burnId = ethers.keccak256(proof);
    const registerReceipt = await send(
      `burn proof ${j + 1} (${ethers.formatUnits(amount, 6)} USDC)`,
      verifier.registerBurn(proof, {
        chainId,
        treasury: treasuryAddress,
        token: usdcAddress,
        recipient: deployer.address,
        amount,
        burnId,
      }),
    );
    const releaseReceipt = await send(`withdrawal ${j + 1}`, treasury.release(proof));
    const transfers = releaseReceipt.logs
      .map((log: any) => {
        try {
          return usdc.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .filter((parsed: any) => parsed?.name === "Transfer")
      .map((parsed: any) => ({ from: parsed.args.from, to: parsed.args.to, amount: parsed.args.value.toString() }));
    acceptance.withdrawals.push({
      index: j + 1,
      amount: amount.toString(),
      burnId,
      registerTxHash: registerReceipt.hash,
      releaseTxHash: releaseReceipt.hash,
      blockNumber: releaseReceipt.blockNumber,
      previewedUnits: [...selected],
      previewedAmounts: [...takes].map((value: bigint) => value.toString()),
      transfers,
    });
  }

  // 6. On-chain checks: the script fails if any invariant does not hold
  const buckets = await treasury.buckets(usdcAddress);
  const principal = await treasury.principalOf(usdcAddress);
  const treasuryBalance = await usdc.balanceOf(treasuryAddress);
  const units: any[] = [];
  for (const d of acceptance.deposits) {
    const record = await treasury.units(d.unit);
    const tokenBalance = await usdc.balanceOf(d.unit);
    if (tokenBalance !== record.remaining) {
      throw new Error(`unit ${d.index} holds ${tokenBalance} but registers ${record.remaining}`);
    }
    units.push({
      index: d.index,
      unit: d.unit,
      status: UNIT_STATUS[Number(record.status)],
      remaining: record.remaining.toString(),
      tokenBalance: tokenBalance.toString(),
    });
  }
  if (treasuryBalance !== 0n) throw new Error(`treasury holds ${treasuryBalance} at rest`);
  const expectedPrincipal = total - sum(WITHDRAWAL_AMOUNTS);
  if (principal !== expectedPrincipal) throw new Error(`principal ${principal} != expected ${expectedPrincipal}`);
  const bucketSum = buckets.registered + buckets.active + buckets.restricted + buckets.unverified;
  if (bucketSum !== principal) throw new Error(`buckets sum ${bucketSum} != principal ${principal}`);

  acceptance.finalState = {
    buckets: {
      registered: buckets.registered.toString(),
      active: buckets.active.toString(),
      restricted: buckets.restricted.toString(),
      unverified: buckets.unverified.toString(),
      confirmedLoss: buckets.confirmedLoss.toString(),
    },
    principal: principal.toString(),
    treasuryTokenBalance: treasuryBalance.toString(),
    deployerTokenBalance: (await usdc.balanceOf(deployer.address)).toString(),
    units,
  };

  const output = {
    network: chainId === BASE_SEPOLIA_CHAIN_ID ? "baseSepolia" : `local-${chainId}`,
    chainId: chainId.toString(),
    deployer: deployer.address,
    deployedAt: new Date().toISOString(),
    params: {
      maxProofAgeBlocks: MAX_PROOF_AGE.toString(),
      perDepositCapRaw: CAP.toString(),
      tokenDecimals: 6,
      maxUnitsPerPayment: 16,
    },
    contracts,
    acceptance,
  };

  console.log("=".repeat(60));
  console.log(JSON.stringify(output, null, 2));

  if (chainId === BASE_SEPOLIA_CHAIN_ID) {
    const file = path.resolve(__dirname, "..", "deployments", "baseSepolia-ExternalTreasuryUnits.json");
    fs.writeFileSync(file, JSON.stringify(output, null, 2) + "\n");
    console.log("written:", file);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
