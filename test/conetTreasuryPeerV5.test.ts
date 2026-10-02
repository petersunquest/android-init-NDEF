import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

const BOOTSTRAP = "0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1";
const GB_UNIT = 10n ** 9n;
const TOKENS_PER_GB = 100n * 10n ** 18n;
const USDC_PER_GB = 1_000_000n;

async function fund(address: string, wei: bigint) {
  await ethers.provider.send("hardhat_setBalance", [address, "0x" + wei.toString(16)]);
}

async function impersonate(address: string) {
  await ethers.provider.send("hardhat_impersonateAccount", [address]);
  await fund(address, 1000n * 10n ** 18n);
  return ethers.getSigner(address);
}

describe("ConetTreasuryPeerV5", function () {
  it("covers rate votes, developer ERC20, GB settlement, and offline USDC withdraw", async function () {
    const [miner, user, mailbox, recipient] = await ethers.getSigners();
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const bootstrap = await impersonate(BOOTSTRAP);

    const usdc2 = await ethers.deployContract("PeerV5MockUsdc", [ethers.ZeroAddress]);
    await usdc2.waitForDeployment();
    const bridge2 = await ethers.deployContract("PeerV5MockBridge", [await usdc2.getAddress(), 100n]);
    await bridge2.waitForDeployment();
    await usdc2.setBurner(await bridge2.getAddress());

    const guardians = await ethers.deployContract("PeerV5MockGuardians");
    await guardians.waitForDeployment();
    const treasury = await ethers.deployContract("ConetTreasuryPeerV5");
    await treasury.waitForDeployment();

    const gbForTreasury = await ethers.deployContract("PeerV5MockGb", [await treasury.getAddress()]);
    await gbForTreasury.waitForDeployment();

    await treasury.connect(bootstrap).configure(
      await gbForTreasury.getAddress(),
      await usdc2.getAddress(),
      await bridge2.getAddress(),
      await guardians.getAddress(),
      chainId,
    );
    await treasury.connect(bootstrap).addMiner(miner.address);
    await guardians.setOwner(7, mailbox.address);

    await fund(user.address, 1000n * 10n ** 18n);
    await treasury.connect(user).registerVoter();
    const proposal = await treasury.connect(user).propose(1, USDC_PER_GB);
    await proposal.wait();
    await treasury.connect(user).vote(1);
    expect(await treasury.usdc6PerFullGb()).to.equal(USDC_PER_GB);

    const boundTx = await treasury.connect(miner).createERC20("App", "APP", 18, true, TOKENS_PER_GB);
    await boundTx.wait();
    const freeTx = await treasury.connect(miner).createERC20("Free", "FREE", 18, false, 0);
    await freeTx.wait();
    const bound = await ethers.getContractAt("PeerV5DeveloperERC20", await treasury.createdTokens(0));
    const free = await ethers.getContractAt("PeerV5DeveloperERC20", await treasury.createdTokens(1));
    expect(await bound.gbBound()).to.equal(true);
    await expect(bound.connect(user).transfer(mailbox.address, 1)).to.revert(ethers);
    await treasury.connect(miner).mintDeveloper(await free.getAddress(), user.address, 5n);
    await free.connect(user).transfer(mailbox.address, 2n);
    expect(await free.balanceOf(mailbox.address)).to.equal(2n);

    await treasury.connect(miner).mintDeveloper(await bound.getAddress(), user.address, TOKENS_PER_GB);
    await usdc2.mint(user.address, 2n * USDC_PER_GB);
    const authNonce = ethers.id("deposit-1");
    const usdcDomain = {
      name: "CoNET USD Coin",
      version: "1",
      chainId,
      verifyingContract: await usdc2.getAddress(),
    };
    const authTypes = {
      TransferWithAuthorization: [
        { name: "from", type: "address" },
        { name: "to", type: "address" },
        { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce", type: "bytes32" },
      ],
    };
    const transferSig = await user.signTypedData(usdcDomain, authTypes, {
      from: user.address,
      to: await treasury.getAddress(),
      value: USDC_PER_GB,
      validAfter: 0,
      validBefore: 2n ** 64n,
      nonce: authNonce,
    });
    const depositSig = await user.signTypedData(
      { name: "ConetTreasuryPeerV5", version: "1", chainId, verifyingContract: await treasury.getAddress() },
      {
        DepositGb: [
          { name: "user", type: "address" },
          { name: "token", type: "address" },
          { name: "usdcAmount", type: "uint256" },
          { name: "minGb", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      {
        user: user.address,
        token: await bound.getAddress(),
        usdcAmount: USDC_PER_GB,
        minGb: GB_UNIT,
        nonce: 0,
        deadline: 2n ** 64n,
      },
    );
    await treasury.depositGbWithSignature(
      user.address,
      await bound.getAddress(),
      USDC_PER_GB,
      GB_UNIT,
      0,
      2n ** 64n,
      depositSig,
      0,
      2n ** 64n,
      authNonce,
      transferSig,
    );
    expect(await gbForTreasury.balanceOf(await bound.getAddress())).to.equal(GB_UNIT);

    await treasury.connect(user).registerMiner(7);
    await bound.connect(user).approve(await treasury.getAddress(), TOKENS_PER_GB);
    await treasury.connect(mailbox).settleDeveloperToken(user.address, await bound.getAddress(), 1);
    expect(await gbForTreasury.balanceOf(mailbox.address)).to.equal(GB_UNIT);
    expect(await bound.balanceOf(user.address)).to.equal(0n);

    await gbForTreasury.faucet(user.address, GB_UNIT);
    await usdc2.mint(await treasury.getAddress(), USDC_PER_GB);
    await gbForTreasury.connect(user).approve(await treasury.getAddress(), GB_UNIT);
    await treasury.connect(user).redeemGb(GB_UNIT);
    expect(await usdc2.balanceOf(user.address)).to.equal(USDC_PER_GB + USDC_PER_GB);

    const principal = 1_000_000n;
    const fee = principal / 100n;
    const withdrawAuth = ethers.id("withdraw-1");
    const beneficiaries = [recipient.address];
    const amounts = [principal];
    const beneficiariesHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(["address[]", "uint256[]"], [beneficiaries, amounts]),
    );
    const pullSig = await user.signTypedData(usdcDomain, authTypes, {
      from: user.address,
      to: await treasury.getAddress(),
      value: principal + fee,
      validAfter: 0,
      validBefore: 2n ** 64n,
      nonce: withdrawAuth,
    });
    const withdrawSig = await user.signTypedData(
      { name: "ConetTreasuryPeerV5", version: "1", chainId, verifyingContract: await treasury.getAddress() },
      {
        InitiateBurnRelease: [
          { name: "user", type: "address" },
          { name: "sourceAsset", type: "address" },
          { name: "destinationChainId", type: "uint256" },
          { name: "destinationAsset", type: "address" },
          { name: "beneficiariesHash", type: "bytes32" },
          { name: "sourceTxHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      {
        user: user.address,
        sourceAsset: await usdc2.getAddress(),
        destinationChainId: 8453,
        destinationAsset: recipient.address,
        beneficiariesHash,
        sourceTxHash: ethers.ZeroHash,
        nonce: 0,
        deadline: 2n ** 64n,
      },
    );
    await usdc2.mint(user.address, principal + fee);
    await treasury.withdrawUsdcWithSignature(
      {
        user: user.address,
        destinationChainId: 8453,
        destinationAsset: recipient.address,
        beneficiaries,
        amounts,
        sourceTxHash: ethers.ZeroHash,
        bridgeNonce: 1,
        validAfter: 0,
        validBefore: 2n ** 64n,
        authNonce: withdrawAuth,
        nonce: 0,
        deadline: 2n ** 64n,
      },
      pullSig,
      withdrawSig,
    );
    expect(await bridge2.lastPrincipal()).to.equal(principal);
    expect(await bridge2.lastDestChain()).to.equal(8453n);
    expect(await usdc2.balanceOf(await bridge2.getAddress())).to.equal(fee);
  });
});
