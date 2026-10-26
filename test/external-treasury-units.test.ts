import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

const ONE_USDC = 1_000_000n; // 6 decimals
const CAP = 1_000n * ONE_USDC; // per-deposit cap set at deployment
const MAX_PROOF_AGE = 50n; // blocks

// Unit statuses, as numbered in ExternalTreasuryUnits.
const REGISTERED = 1n;
const ACTIVE = 2n;
const RESTRICTED = 3n;
const RECON_PENDING = 4n;
const SPENT = 5n;
const LOSS_CONFIRMED = 6n;

const COMMIT_A = ethers.id("conet-beneficiary-a");
const COMMIT_B = ethers.id("conet-beneficiary-b");

async function deploy(name: string, args: unknown[] = []): Promise<any> {
  const contract = await (await ethers.getContractFactory(name)).deploy(...args);
  await contract.waitForDeployment();
  return contract;
}

let proofSeq = 0;
/// Mock proofs are unique bytes that the test registers with a mock verifier.
function freshProof(kind: string): string {
  proofSeq += 1;
  return ethers.hexlify(ethers.toUtf8Bytes(`${kind}-${proofSeq}`));
}

async function currentBlock(): Promise<bigint> {
  return BigInt(await ethers.provider.getBlockNumber());
}

async function setup() {
  const [, alice, bob, outsider] = await ethers.getSigners();
  const chainId = (await ethers.provider.getNetwork()).chainId;
  const verifier = await deploy("ExternalTreasuryMockVerifier");
  const stateVerifier = await deploy("UnitStateMockVerifier");
  const implementation = await deploy("DepositUnit");
  const usdc = await deploy("DepositUnitMockUSDC");
  const treasury = await deploy("ExternalTreasuryUnits", [
    verifier.target,
    stateVerifier.target,
    implementation.target,
    MAX_PROOF_AGE,
    [usdc.target],
    [CAP],
  ]);
  const factory = await ethers.getContractAt("DepositUnitFactory", await treasury.FACTORY());
  return { alice, bob, outsider, chainId, verifier, stateVerifier, implementation, usdc, treasury, factory };
}

type World = Awaited<ReturnType<typeof setup>>;

/// A proof that a unit's restriction state and balance were as given at a block (the current block by default).
async function stateProof(
  w: World,
  unit: string,
  fields: {
    balance: bigint;
    restricted?: boolean;
    token?: string;
    treasury?: string;
    chainId?: bigint;
    blockNumber?: bigint;
  },
): Promise<string> {
  const proof = freshProof("state");
  await w.stateVerifier.registerUnitState(proof, {
    chainId: fields.chainId ?? w.chainId,
    treasury: fields.treasury ?? w.treasury.target,
    unit,
    token: fields.token ?? w.usdc.target,
    restricted: fields.restricted ?? false,
    balance: fields.balance,
    blockNumber: fields.blockNumber ?? ((await currentBlock()) + 1n), // the report mines after this proof's block
  });
  return proof;
}

async function report(w: World, unit: string, fields: Parameters<typeof stateProof>[2]): Promise<void> {
  await w.treasury.reportUnitState(await stateProof(w, unit, fields));
}

/// Reports a unit unrestricted at the given balance. This is what makes a registered unit payable.
async function activate(w: World, unit: string, balance: bigint): Promise<void> {
  await report(w, unit, { balance });
}

async function burnProof(w: World, recipient: string, amount: bigint): Promise<{ proof: string; burnId: string }> {
  const proof = freshProof("burn");
  const burnId = ethers.id(proof);
  await w.verifier.registerBurn(proof, {
    chainId: w.chainId,
    treasury: w.treasury.target,
    token: w.usdc.target,
    recipient,
    amount,
    burnId,
  });
  return { proof, burnId };
}

async function refundProof(w: World, depositId: string, depositor: string, amount: bigint): Promise<string> {
  const proof = freshProof("refund");
  await w.verifier.registerRefund(proof, {
    chainId: w.chainId,
    treasury: w.treasury.target,
    depositId,
    token: w.usdc.target,
    depositor,
    amount,
  });
  return proof;
}

async function lossProof(w: World, unit: string, amount: bigint): Promise<string> {
  const proof = freshProof("loss");
  await w.stateVerifier.registerUnitLoss(proof, {
    chainId: w.chainId,
    treasury: w.treasury.target,
    unit,
    token: w.usdc.target,
    amount,
    blockNumber: (await currentBlock()) + 1n,
  });
  return proof;
}

async function allowlistProof(w: World, token: string, add: boolean, version: bigint, cap: bigint): Promise<string> {
  const proof = freshProof("allowlist");
  await w.verifier.registerAllowlist(proof, {
    chainId: w.chainId,
    treasury: w.treasury.target,
    token,
    add,
    version,
    cap,
    codeHash: ethers.ZeroHash,
  });
  return proof;
}

/// Funds `who` and deposits into the treasury. Returns the deposit identifier and the unit that holds it.
async function deposit(w: World, who: any, amount: bigint, commitment: string = COMMIT_A) {
  await w.usdc.mint(who.address, amount);
  await w.usdc.connect(who).approve(w.treasury.target, amount);
  const receipt = await (await w.treasury.connect(who).deposit(w.usdc.target, amount, commitment)).wait();
  const event = receipt.logs
    .map((log: any) => w.treasury.interface.parseLog(log))
    .find((parsed: any) => parsed?.name === "Deposited");
  const depositId = event.args.depositId as string;
  return { depositId, unit: (await w.treasury.unitOf(depositId)) as string };
}

/// Checks each bucket against the live units, and that principal equals the sum of the registered, active,
/// restricted and unverified buckets.
async function expectAccountingMatches(w: World) {
  const token = w.usdc.target;
  const sums = { registered: 0n, active: 0n, restricted: 0n, unverified: 0n };
  const count = Number(await w.treasury.queueLength(token));
  for (let i = 0; i < count; i++) {
    const u = await w.treasury.units(await w.treasury.queuedUnit(token, i));
    const status = BigInt(u.status);
    if (status === REGISTERED) sums.registered += u.remaining;
    if (status === ACTIVE) sums.active += u.remaining;
    if (status === RESTRICTED) sums.restricted += u.remaining;
    if (status === RECON_PENDING) sums.unverified += u.remaining;
  }
  const b = await w.treasury.buckets(token);
  expect(b.registered).to.equal(sums.registered);
  expect(b.active).to.equal(sums.active);
  expect(b.restricted).to.equal(sums.restricted);
  expect(b.unverified).to.equal(sums.unverified);
  expect(await w.treasury.principalOf(token)).to.equal(
    sums.registered + sums.active + sums.restricted + sums.unverified,
  );
}

describe("ExternalTreasuryUnits", function () {
  it("exposes no admin surface on the treasury, the factory or a unit", async function () {
    const w = await setup();
    const banned = [
      "owner",
      "transferOwnership",
      "pause",
      "unpause",
      "upgradeTo",
      "upgradeToAndCall",
      "withdraw",
      "sweep",
      "setVerifier",
      "setTreasury",
    ];
    for (const contract of [w.treasury, w.factory, w.implementation]) {
      const names = contract.interface.fragments.filter((f: any) => f.type === "function").map((f: any) => f.name);
      for (const name of banned) expect(names).to.not.include(name);
    }
  });

  it("deposits straight into a unit derived for that deposit, and the treasury holds nothing", async function () {
    const w = await setup();
    const amount = 100n * ONE_USDC;
    const a = await deposit(w, w.alice, amount, COMMIT_A);
    expect(await w.factory.predictUnit(a.depositId, w.usdc.target)).to.equal(a.unit);
    expect(await w.usdc.balanceOf(a.unit)).to.equal(amount);
    expect(await w.usdc.balanceOf(w.treasury.target)).to.equal(0n);

    const u = await w.treasury.units(a.unit);
    expect(BigInt(u.status)).to.equal(REGISTERED);
    expect(u.remaining).to.equal(amount);
    expect(u.token).to.equal(w.usdc.target);

    const rec = await w.treasury.deposits(a.depositId);
    expect(rec.depositor).to.equal(w.alice.address);
    expect(rec.beneficiaryCommitment).to.equal(COMMIT_A);
    expect(rec.refunded).to.equal(false);

    const unit = await ethers.getContractAt("DepositUnit", a.unit);
    expect(await unit.treasury()).to.equal(w.treasury.target);
    expect(await unit.token()).to.equal(w.usdc.target);
    expect(await unit.factory()).to.equal(w.factory.target);
    expect(await w.treasury.principalOf(w.usdc.target)).to.equal(amount);
  });

  it("gives every deposit its own unit, even for the same amount and commitment", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC, COMMIT_A);
    const b = await deposit(w, w.bob, 100n * ONE_USDC, COMMIT_A);
    expect(a.unit).to.not.equal(b.unit);
    expect(a.depositId).to.not.equal(b.depositId);
  });

  it("counts only the registered amount when unsolicited tokens reached the predicted unit first", async function () {
    const w = await setup();
    const amount = 100n * ONE_USDC;
    const dust = 1n * ONE_USDC;
    const nonce = await w.treasury.depositNonce();
    const depositId = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "address", "address", "address", "uint256", "bytes32", "uint256"],
        [w.chainId, w.treasury.target, w.usdc.target, w.alice.address, amount, COMMIT_A, nonce],
      ),
    );
    const predicted = await w.factory.predictUnit(depositId, w.usdc.target);
    await w.usdc.mint(w.outsider.address, dust);
    await w.usdc.connect(w.outsider).transfer(predicted, dust);

    const a = await deposit(w, w.alice, amount, COMMIT_A);
    expect(a.depositId).to.equal(depositId);
    expect(a.unit).to.equal(predicted);
    expect(await w.usdc.balanceOf(a.unit)).to.equal(amount + dust);
    expect(await w.treasury.principalOf(w.usdc.target)).to.equal(amount);

    await activate(w, a.unit, amount + dust);
    const burn = await burnProof(w, w.bob.address, amount);
    await w.treasury.release(burn.proof);
    expect(await w.usdc.balanceOf(w.bob.address)).to.equal(amount);
    expect(await w.usdc.balanceOf(a.unit)).to.equal(dust); // unregistered dust is never paid out
    expect(await w.treasury.principalOf(w.usdc.target)).to.equal(0n);
    await expectAccountingMatches(w);
  });

  it("does not let anyone initialise the implementation or a unit that is already bound", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, ONE_USDC);
    const impl = await ethers.getContractAt("DepositUnit", w.implementation.target);
    await expect(impl.initialize(w.outsider.address, w.usdc.target)).to.be.revertedWithCustomError(
      impl,
      "AlreadyBound",
    );
    const unit = await ethers.getContractAt("DepositUnit", a.unit);
    await expect(unit.initialize(w.outsider.address, w.usdc.target)).to.be.revertedWithCustomError(
      unit,
      "AlreadyBound",
    );
  });

  it("accepts unit creation and unit payment only from the treasury", async function () {
    const w = await setup();
    await expect(
      w.factory.connect(w.outsider).createUnit(ethers.ZeroHash, w.usdc.target),
    ).to.be.revertedWithCustomError(w.factory, "NotTreasury");
    const a = await deposit(w, w.alice, ONE_USDC);
    const unit = await ethers.getContractAt("DepositUnit", a.unit);
    await expect(unit.connect(w.outsider).pay(w.outsider.address, ONE_USDC)).to.be.revertedWithCustomError(
      unit,
      "NotTreasury",
    );
  });

  it("refuses to deploy against an implementation address with no code", async function () {
    const w = await setup();
    const treasuryFactory = await ethers.getContractFactory("ExternalTreasuryUnits");
    await expect(
      treasuryFactory.deploy(
        w.verifier.target,
        w.stateVerifier.target,
        w.outsider.address,
        MAX_PROOF_AGE,
        [w.usdc.target],
        [CAP],
      ),
    ).to.be.revertedWithCustomError(treasuryFactory, "ImplementationNotDeployed");
  });

  it("rejects an unlisted token, a zero amount, a zero commitment and an amount above the cap", async function () {
    const w = await setup();
    const other = await deploy("DepositUnitMockUSDC");
    await other.mint(w.alice.address, ONE_USDC);
    await other.connect(w.alice).approve(w.treasury.target, ONE_USDC);
    await expect(
      w.treasury.connect(w.alice).deposit(other.target, ONE_USDC, COMMIT_A),
    ).to.be.revertedWithCustomError(w.treasury, "NotListed");

    await w.usdc.mint(w.alice.address, CAP + ONE_USDC);
    await w.usdc.connect(w.alice).approve(w.treasury.target, CAP + ONE_USDC);
    await expect(
      w.treasury.connect(w.alice).deposit(w.usdc.target, 0n, COMMIT_A),
    ).to.be.revertedWithCustomError(w.treasury, "ZeroAmount");
    await expect(
      w.treasury.connect(w.alice).deposit(w.usdc.target, ONE_USDC, ethers.ZeroHash),
    ).to.be.revertedWithCustomError(w.treasury, "ZeroCommitment");
    await expect(
      w.treasury.connect(w.alice).deposit(w.usdc.target, CAP + ONE_USDC, COMMIT_A),
    ).to.be.revertedWithCustomError(w.treasury, "OverCap");
  });

  it("rejects a token that delivers less than the amount, because only fully modelled tokens are accepted", async function () {
    const w = await setup();
    const fee = await deploy("ExternalTreasuryFeeToken");
    await w.treasury.applyAllowlist(await allowlistProof(w, fee.target, true, 1n, CAP));
    await fee.mint(w.alice.address, ONE_USDC);
    await fee.connect(w.alice).approve(w.treasury.target, ONE_USDC);
    await expect(w.treasury.connect(w.alice).deposit(fee.target, ONE_USDC, COMMIT_A))
      .to.be.revertedWithCustomError(w.treasury, "UnsupportedTokenSemantics")
      .withArgs(ONE_USDC, (ONE_USDC * 99n) / 100n);
  });

  it("keeps a new unit out of payments until a verified state proof activates it", async function () {
    const w = await setup();
    const amount = 100n * ONE_USDC;
    const a = await deposit(w, w.alice, amount);
    const burn = await burnProof(w, w.bob.address, 60n * ONE_USDC);
    await expect(w.treasury.release(burn.proof))
      .to.be.revertedWithCustomError(w.treasury, "InsufficientActiveReserves")
      .withArgs(0n, 60n * ONE_USDC);
    expect(await w.treasury.burnConsumed(burn.burnId)).to.equal(false); // a failed release consumes nothing

    await activate(w, a.unit, amount);
    await w.treasury.release(burn.proof);
    expect(await w.usdc.balanceOf(w.bob.address)).to.equal(60n * ONE_USDC);
    expect((await w.treasury.buckets(w.usdc.target)).active).to.equal(40n * ONE_USDC);
    await expectAccountingMatches(w);
  });

  it("rejects a state proof from before the deposit, so an earlier state cannot activate the unit", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    const depositBlock = await currentBlock();
    await expect(
      w.treasury.reportUnitState(await stateProof(w, a.unit, { balance: 100n * ONE_USDC, blockNumber: depositBlock })),
    ).to.be.revertedWithCustomError(w.treasury, "StaleProof");
    expect(BigInt((await w.treasury.units(a.unit)).status)).to.equal(REGISTERED);
  });

  it("pays first in first out and marks a unit spent once it is used up", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    const b = await deposit(w, w.bob, 50n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    await activate(w, b.unit, 50n * ONE_USDC);

    const [selected, takes] = await w.treasury.previewPayment(w.usdc.target, 120n * ONE_USDC);
    expect([...selected]).to.deep.equal([a.unit, b.unit]);
    expect([...takes]).to.deep.equal([100n * ONE_USDC, 20n * ONE_USDC]);

    const burn = await burnProof(w, w.outsider.address, 120n * ONE_USDC);
    await w.treasury.release(burn.proof);
    expect(await w.usdc.balanceOf(w.outsider.address)).to.equal(120n * ONE_USDC);
    expect(BigInt((await w.treasury.units(a.unit)).status)).to.equal(SPENT);
    expect((await w.treasury.units(b.unit)).remaining).to.equal(30n * ONE_USDC);
    expect(await w.treasury.queueHead(w.usdc.target)).to.equal(1n);
    await expect(
      w.treasury.reportUnitState(await stateProof(w, a.unit, { balance: 0n })),
    ).to.be.revertedWithCustomError(w.treasury, "UnitClosed");
    await expectAccountingMatches(w);
  });

  it("draws the next payment from the partly drawn unit before later units", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    const b = await deposit(w, w.bob, 50n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    await activate(w, b.unit, 50n * ONE_USDC);
    const first = await burnProof(w, w.outsider.address, 120n * ONE_USDC);
    await w.treasury.release(first.proof);
    expect(BigInt((await w.treasury.units(a.unit)).status)).to.equal(SPENT);
    expect((await w.treasury.units(b.unit)).remaining).to.equal(30n * ONE_USDC);
    expect(BigInt((await w.treasury.units(b.unit)).status)).to.equal(ACTIVE);

    const [selected, takes] = await w.treasury.previewPayment(w.usdc.target, 30n * ONE_USDC);
    expect([...selected]).to.deep.equal([b.unit]);
    expect([...takes]).to.deep.equal([30n * ONE_USDC]);

    const second = await burnProof(w, w.outsider.address, 30n * ONE_USDC);
    await w.treasury.release(second.proof);
    expect(BigInt((await w.treasury.units(b.unit)).status)).to.equal(SPENT);
    expect(await w.usdc.balanceOf(w.outsider.address)).to.equal(150n * ONE_USDC);
    await expectAccountingMatches(w);
  });

  it("consumes each burn proof once and never pays the zero address", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    const burn = await burnProof(w, w.outsider.address, 10n * ONE_USDC);
    await w.treasury.release(burn.proof);
    await expect(w.treasury.release(burn.proof)).to.be.revertedWithCustomError(w.treasury, "AlreadyConsumed");

    const toZero = await burnProof(w, ethers.ZeroAddress, 1n * ONE_USDC);
    await expect(w.treasury.release(toZero.proof)).to.be.revertedWithCustomError(w.treasury, "ZeroAddress");
  });

  it("reverts a multi-unit release as a whole when one unit cannot transfer, then routes around it once restricted", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    const b = await deposit(w, w.bob, 50n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    await activate(w, b.unit, 50n * ONE_USDC);
    await w.usdc.setBlacklisted(b.unit, true); // the token refuses to move unit b, but no proof has said so yet

    const failing = await burnProof(w, w.outsider.address, 120n * ONE_USDC);
    await expect(w.treasury.release(failing.proof)).to.be.revert(ethers);
    expect(await w.treasury.burnConsumed(failing.burnId)).to.equal(false);
    expect(await w.usdc.balanceOf(w.outsider.address)).to.equal(0n);
    expect((await w.treasury.units(a.unit)).remaining).to.equal(100n * ONE_USDC);
    expect(BigInt((await w.treasury.units(b.unit)).status)).to.equal(ACTIVE); // a failed transfer freezes nothing

    await report(w, b.unit, { restricted: true, balance: 50n * ONE_USDC });
    const routed = await burnProof(w, w.outsider.address, 100n * ONE_USDC);
    await w.treasury.release(routed.proof);
    expect(await w.usdc.balanceOf(w.outsider.address)).to.equal(100n * ONE_USDC);
    expect(BigInt((await w.treasury.units(a.unit)).status)).to.equal(SPENT);
    expect((await w.treasury.buckets(w.usdc.target)).restricted).to.equal(50n * ONE_USDC);
    await expectAccountingMatches(w);
  });

  it("moves a unit between active and restricted on verified proofs, and payments skip a restricted unit", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    const b = await deposit(w, w.bob, 50n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    await activate(w, b.unit, 50n * ONE_USDC);

    await report(w, a.unit, { restricted: true, balance: 100n * ONE_USDC });
    let buckets = await w.treasury.buckets(w.usdc.target);
    expect(buckets.active).to.equal(50n * ONE_USDC);
    expect(buckets.restricted).to.equal(100n * ONE_USDC);
    const [selected] = await w.treasury.previewPayment(w.usdc.target, 30n * ONE_USDC);
    expect([...selected]).to.deep.equal([b.unit]);

    await report(w, a.unit, { balance: 100n * ONE_USDC });
    expect(BigInt((await w.treasury.units(a.unit)).status)).to.equal(ACTIVE);
    buckets = await w.treasury.buckets(w.usdc.target);
    expect(buckets.active).to.equal(150n * ONE_USDC);
    expect(buckets.restricted).to.equal(0n);
    await expectAccountingMatches(w);
  });

  it("reports a balance shortfall as unverified, keeps it out of payments, and clears it when the balance returns", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);

    await report(w, a.unit, { balance: 80n * ONE_USDC });
    expect(BigInt((await w.treasury.units(a.unit)).status)).to.equal(RECON_PENDING);
    let buckets = await w.treasury.buckets(w.usdc.target);
    expect(buckets.unverified).to.equal(100n * ONE_USDC);
    expect(buckets.active).to.equal(0n);
    await expect(w.treasury.previewPayment(w.usdc.target, 10n * ONE_USDC))
      .to.be.revertedWithCustomError(w.treasury, "InsufficientActiveReserves")
      .withArgs(0n, 10n * ONE_USDC);

    await activate(w, a.unit, 100n * ONE_USDC);
    expect(BigInt((await w.treasury.units(a.unit)).status)).to.equal(ACTIVE);
    buckets = await w.treasury.buckets(w.usdc.target);
    expect(buckets.unverified).to.equal(0n);
    expect(buckets.active).to.equal(100n * ONE_USDC);
    await expectAccountingMatches(w);
  });

  it("rejects proofs that are replayed, older than the last accepted one, from the future, or for another target, token or unit", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    const first = await stateProof(w, a.unit, { balance: 100n * ONE_USDC });
    await w.treasury.reportUnitState(first);
    await expect(w.treasury.reportUnitState(first)).to.be.revertedWithCustomError(w.treasury, "StaleProof");

    const older = await stateProof(w, a.unit, { balance: 100n * ONE_USDC, blockNumber: 1n });
    await expect(w.treasury.reportUnitState(older)).to.be.revertedWithCustomError(w.treasury, "StaleProof");

    const future = await stateProof(w, a.unit, {
      balance: 100n * ONE_USDC,
      blockNumber: (await currentBlock()) + 1000n,
    });
    await expect(w.treasury.reportUnitState(future)).to.be.revertedWithCustomError(w.treasury, "FutureProof");

    const wrongTreasury = await stateProof(w, a.unit, { balance: 100n * ONE_USDC, treasury: w.outsider.address });
    await expect(w.treasury.reportUnitState(wrongTreasury)).to.be.revertedWithCustomError(w.treasury, "WrongTarget");

    const wrongChain = await stateProof(w, a.unit, { balance: 100n * ONE_USDC, chainId: w.chainId + 1n });
    await expect(w.treasury.reportUnitState(wrongChain)).to.be.revertedWithCustomError(w.treasury, "WrongTarget");

    const wrongToken = await stateProof(w, a.unit, { balance: 100n * ONE_USDC, token: w.outsider.address });
    await expect(w.treasury.reportUnitState(wrongToken)).to.be.revertedWithCustomError(w.treasury, "WrongToken");

    const unknown = await stateProof(w, w.outsider.address, { balance: 1n });
    await expect(w.treasury.reportUnitState(unknown)).to.be.revertedWithCustomError(w.treasury, "UnknownUnit");
  });

  it("blocks payments from a unit whose last proof is older than the freshness window until it is refreshed", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    const burn = await burnProof(w, w.outsider.address, 10n * ONE_USDC);

    await ethers.provider.send("hardhat_mine", ["0x" + (MAX_PROOF_AGE + 1n).toString(16)]);
    await expect(w.treasury.release(burn.proof)).to.be.revertedWithCustomError(w.treasury, "StaleUnitState");

    await activate(w, a.unit, 100n * ONE_USDC);
    await w.treasury.release(burn.proof);
    expect(await w.usdc.balanceOf(w.outsider.address)).to.equal(10n * ONE_USDC);
  });

  it("refuses a partly drawn unit whose last proof has aged out, and draws its leftover once refreshed", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    const first = await burnProof(w, w.outsider.address, 40n * ONE_USDC);
    await w.treasury.release(first.proof);
    expect((await w.treasury.units(a.unit)).remaining).to.equal(60n * ONE_USDC);

    // A partial payment does not refresh the proof, so the leftover ages like any other unit.
    await ethers.provider.send("hardhat_mine", ["0x" + (MAX_PROOF_AGE + 1n).toString(16)]);
    await expect(w.treasury.previewPayment(w.usdc.target, 10n * ONE_USDC)).to.be.revertedWithCustomError(
      w.treasury,
      "StaleUnitState",
    );

    await activate(w, a.unit, 60n * ONE_USDC);
    const [selected, takes] = await w.treasury.previewPayment(w.usdc.target, 10n * ONE_USDC);
    expect([...selected]).to.deep.equal([a.unit]);
    expect([...takes]).to.deep.equal([10n * ONE_USDC]);
    const third = await burnProof(w, w.outsider.address, 10n * ONE_USDC);
    await w.treasury.release(third.proof);
    expect(await w.usdc.balanceOf(w.outsider.address)).to.equal(50n * ONE_USDC);
    await expectAccountingMatches(w);
  });

  it("refunds a deposit once, from the pooled active reserves in queue order", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    const b = await deposit(w, w.bob, 50n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    await activate(w, b.unit, 50n * ONE_USDC);

    const proof = await refundProof(w, a.depositId, w.alice.address, 100n * ONE_USDC);
    await w.treasury.refund(proof);
    expect(await w.usdc.balanceOf(w.alice.address)).to.equal(100n * ONE_USDC);
    expect((await w.treasury.deposits(a.depositId)).refunded).to.equal(true);
    expect(BigInt((await w.treasury.units(a.unit)).status)).to.equal(SPENT);
    await expect(w.treasury.refund(proof)).to.be.revertedWithCustomError(w.treasury, "AlreadyRefunded");
    await expectAccountingMatches(w);
  });

  it("rejects a refund that does not match its deposit, or names an unknown deposit", async function () {
    const w = await setup();
    const b = await deposit(w, w.bob, 50n * ONE_USDC);
    await activate(w, b.unit, 50n * ONE_USDC);
    await expect(
      w.treasury.refund(await refundProof(w, b.depositId, w.alice.address, 50n * ONE_USDC)),
    ).to.be.revertedWithCustomError(w.treasury, "RefundMismatch");
    await expect(
      w.treasury.refund(await refundProof(w, b.depositId, w.bob.address, 49n * ONE_USDC)),
    ).to.be.revertedWithCustomError(w.treasury, "RefundMismatch");
    await expect(
      w.treasury.refund(await refundProof(w, ethers.id("unknown deposit"), w.bob.address, 1n)),
    ).to.be.revertedWithCustomError(w.treasury, "UnknownDeposit");
  });

  it("writes off a confirmed loss against the unit, and closes the unit once its principal is gone", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);

    await w.treasury.confirmLoss(await lossProof(w, a.unit, 30n * ONE_USDC));
    let u = await w.treasury.units(a.unit);
    expect(u.remaining).to.equal(70n * ONE_USDC);
    expect(BigInt(u.status)).to.equal(ACTIVE);
    let buckets = await w.treasury.buckets(w.usdc.target);
    expect(buckets.active).to.equal(70n * ONE_USDC);
    expect(buckets.confirmedLoss).to.equal(30n * ONE_USDC);
    await expectAccountingMatches(w);

    await w.treasury.confirmLoss(await lossProof(w, a.unit, 70n * ONE_USDC));
    u = await w.treasury.units(a.unit);
    expect(BigInt(u.status)).to.equal(LOSS_CONFIRMED);
    expect(await w.treasury.principalOf(w.usdc.target)).to.equal(0n);
    await expect(
      w.treasury.reportUnitState(await stateProof(w, a.unit, { balance: 0n })),
    ).to.be.revertedWithCustomError(w.treasury, "UnitClosed");
    await expect(w.treasury.confirmLoss(await lossProof(w, a.unit, 1n))).to.be.revertedWithCustomError(
      w.treasury,
      "UnitClosed",
    );
    await expectAccountingMatches(w);
  });

  it("rejects a loss larger than the unit's remaining principal", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 50n * ONE_USDC);
    await expect(w.treasury.confirmLoss(await lossProof(w, a.unit, 60n * ONE_USDC)))
      .to.be.revertedWithCustomError(w.treasury, "LossOutOfRange")
      .withArgs(60n * ONE_USDC, 50n * ONE_USDC);
  });

  it("leaves every unit as it was while the token is paused, and pays once it is unpaused", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    const burn = await burnProof(w, w.outsider.address, 10n * ONE_USDC);

    await w.usdc.setPaused(true);
    await expect(w.treasury.release(burn.proof)).to.be.revert(ethers);
    expect(await w.treasury.burnConsumed(burn.burnId)).to.equal(false);
    expect((await w.treasury.units(a.unit)).remaining).to.equal(100n * ONE_USDC);

    await w.usdc.setPaused(false);
    await w.treasury.release(burn.proof);
    expect(await w.usdc.balanceOf(w.outsider.address)).to.equal(10n * ONE_USDC);
  });

  it("stops new deposits when a token is delisted, while its existing units keep paying", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    await w.treasury.applyAllowlist(await allowlistProof(w, w.usdc.target, false, 1n, 0n));

    await w.usdc.mint(w.bob.address, ONE_USDC);
    await w.usdc.connect(w.bob).approve(w.treasury.target, ONE_USDC);
    await expect(
      w.treasury.connect(w.bob).deposit(w.usdc.target, ONE_USDC, COMMIT_B),
    ).to.be.revertedWithCustomError(w.treasury, "NotListed");

    const burn = await burnProof(w, w.outsider.address, 40n * ONE_USDC);
    await w.treasury.release(burn.proof);
    expect(await w.usdc.balanceOf(w.outsider.address)).to.equal(40n * ONE_USDC);
  });

  it("caps how many units one payment may draw from", async function () {
    const w = await setup();
    const unitsToActivate: string[] = [];
    for (let i = 0; i < 17; i++) {
      unitsToActivate.push((await deposit(w, w.alice, ONE_USDC)).unit);
    }
    // Activate only after every deposit exists, so all 17 proofs are still fresh when the payments are previewed.
    for (const unit of unitsToActivate) await activate(w, unit, ONE_USDC);
    const [selected] = await w.treasury.previewPayment(w.usdc.target, 16n * ONE_USDC);
    expect(selected.length).to.equal(16);
    await expect(w.treasury.previewPayment(w.usdc.target, 17n * ONE_USDC)).to.be.revertedWithCustomError(
      w.treasury,
      "TooManyUnits",
    );
  });

  it("keeps every bucket equal to the live units through a mixed sequence of operations", async function () {
    const w = await setup();
    const a = await deposit(w, w.alice, 100n * ONE_USDC);
    const b = await deposit(w, w.bob, 80n * ONE_USDC);
    const c = await deposit(w, w.outsider, 60n * ONE_USDC);
    await activate(w, a.unit, 100n * ONE_USDC);
    await activate(w, b.unit, 80n * ONE_USDC);
    await activate(w, c.unit, 60n * ONE_USDC);
    await report(w, b.unit, { restricted: true, balance: 80n * ONE_USDC });
    await expectAccountingMatches(w);

    await w.treasury.release((await burnProof(w, w.alice.address, 70n * ONE_USDC)).proof);
    await expectAccountingMatches(w);

    await w.treasury.confirmLoss(await lossProof(w, a.unit, 20n * ONE_USDC));
    await expectAccountingMatches(w);

    await w.treasury.refund(await refundProof(w, c.depositId, w.outsider.address, 60n * ONE_USDC));
    await expectAccountingMatches(w);
    expect(BigInt((await w.treasury.units(a.unit)).status)).to.equal(SPENT);

    await report(w, b.unit, { balance: 80n * ONE_USDC });
    await expectAccountingMatches(w);
    expect(await w.treasury.principalOf(w.usdc.target)).to.equal(90n * ONE_USDC);
  });
});
