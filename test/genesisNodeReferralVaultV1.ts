import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("GenesisNodeReferralVaultV1", function () {
  async function deployStack() {
    const [owner, binder, , l0User, l1User, buyer, foundation, other] = await ethers.getSigners();
    const usdc = await (await ethers.getContractFactory("TreasuryCanonicalERC20V3")).deploy();
    await usdc.waitForDeployment();
    const tokenInit = usdc.interface.encodeFunctionData("initialize", [
      "conet-USDC",
      "USDC",
      6,
      owner.address,
      owner.address,
      "https://mainnet.conet.network/test/erc20/metadata.json",
    ]);
    const tokenProxy = await (
      await ethers.getContractFactory("TreasuryV3ERC1967Proxy")
    ).deploy(await usdc.getAddress(), tokenInit);
    await tokenProxy.waitForDeployment();
    const token = await ethers.getContractAt("TreasuryCanonicalERC20V3", await tokenProxy.getAddress());

    const vaultImpl = await (await ethers.getContractFactory("GenesisNodeReferralVaultV1")).deploy();
    await vaultImpl.waitForDeployment();
    const init = vaultImpl.interface.encodeFunctionData("initialize", [
      owner.address,
      owner.address, // treasury = owner for unit tests
      await token.getAddress(),
      foundation.address,
      owner.address,
      binder.address,
    ]);
    const proxy = await (
      await ethers.getContractFactory("TreasuryV3ERC1967Proxy")
    ).deploy(await vaultImpl.getAddress(), init);
    await proxy.waitForDeployment();
    const vault = await ethers.getContractAt("GenesisNodeReferralVaultV1", await proxy.getAddress());
    await token.connect(owner).setBridge(owner.address);
    return { owner, binder, l0User, l1User, buyer, foundation, other, vault, token };
  }

  async function registerL0(vault: any, owner: any, l0User: any, secret: string) {
    const redeemHash = ethers.keccak256(ethers.toUtf8Bytes(secret));
    await vault.connect(owner).issueL0RedeemCode(redeemHash);
    await vault.connect(l0User).claimL0RedeemCode(ethers.toUtf8Bytes(secret));
  }

  async function registerL1(vault: any, l0User: any, l1User: any, secret: string, ratioBps: bigint) {
    const redeemHash = ethers.keccak256(ethers.toUtf8Bytes(secret));
    await vault.connect(l0User).issueL1RedeemCode(redeemHash, ratioBps);
    await vault.connect(l1User).claimL1RedeemCode(ethers.toUtf8Bytes(secret));
  }

  it("issues and claims L0 redeem", async function () {
    const { owner, l0User, vault } = await deployStack();
    await registerL0(vault, owner, l0User, "beamio-genesis-l0-test-secret-001");
    expect(await vault.isActiveL0(l0User.address)).to.equal(true);
    const m = await vault.members(l0User.address);
    expect(m.parentAdmin).to.equal(owner.address);
  });

  it("L0 issues L1 with ratioBps; non-L0 cannot issue L1", async function () {
    const { owner, l0User, l1User, other, vault } = await deployStack();
    await registerL0(vault, owner, l0User, "beamio-genesis-l0-for-l1");
    await expect(
      vault.connect(other).issueL1RedeemCode(ethers.keccak256(ethers.toUtf8Bytes("x")), 5000n),
    ).to.be.revertedWithCustomError(vault, "NotL0");

    await registerL1(vault, l0User, l1User, "beamio-genesis-l1-40", 4000n);
    expect(await vault.isActiveL1(l1User.address)).to.equal(true);
    const m = await vault.members(l1User.address);
    expect(m.parentL0).to.equal(l0User.address);
    expect(m.ratioBps).to.equal(4000n);
  });

  it("bindSale requires L1 referrer (rejects bare L0)", async function () {
    const { owner, binder, l0User, buyer, vault } = await deployStack();
    await registerL0(vault, owner, l0User, "beamio-genesis-l0-bind");
    const opId = ethers.keccak256(ethers.toUtf8Bytes("sale-bad-l0"));
    await expect(
      vault.connect(binder).bindSale(opId, l0User.address, buyer.address, 1n, false),
    ).to.be.revertedWithCustomError(vault, "NotL1");
  });

  it("splits with L1 ratio: L0 60% + L1 40% of 125 pool", async function () {
    const { owner, binder, l0User, l1User, buyer, foundation, vault, token } = await deployStack();
    await registerL0(vault, owner, l0User, "beamio-genesis-l0-split");
    await registerL1(vault, l0User, l1User, "beamio-genesis-l1-split", 4000n);

    const opId = ethers.keccak256(ethers.toUtf8Bytes("sale-1"));
    await vault.connect(binder).bindSale(opId, l1User.address, buyer.address, 1n, false);

    const [l0Pool, adminAmt, foundAmt, total] = await vault.previewSplit(1n);
    expect(total).to.equal(1_370_000_000n);
    expect(l0Pool).to.equal(125_000_000n);
    expect(adminAmt).to.equal(370_000_000n);
    expect(foundAmt).to.equal(875_000_000n);

    const [l0Amt, l1Amt] = await vault.previewL0L1Split(l0Pool, 4000n);
    expect(l1Amt).to.equal(50_000_000n); // 40% of 125
    expect(l0Amt).to.equal(75_000_000n);

    await token.connect(owner).mint(await vault.getAddress(), total);
    await expect(
      vault
        .connect(owner)
        .onBridgeMint(opId, 8453n, await token.getAddress(), [await vault.getAddress()], [total]),
    )
      .to.emit(vault, "SaleSettled")
      .withArgs(
        opId,
        l0User.address,
        l1User.address,
        owner.address,
        foundation.address,
        l0Amt,
        l1Amt,
        adminAmt,
        foundAmt,
      );

    expect(await token.balanceOf(l0User.address)).to.equal(l0Amt);
    expect(await token.balanceOf(l1User.address)).to.equal(l1Amt);
    expect(await token.balanceOf(owner.address)).to.equal(adminAmt);
    expect(await token.balanceOf(foundation.address)).to.equal(foundAmt);
    expect(await vault.earnedUsdc6(l1User.address)).to.equal(l1Amt);
  });

  it("folds L0 pool into foundation when no L1 referrer", async function () {
    const { owner, binder, buyer, foundation, vault, token } = await deployStack();
    const opId = ethers.keccak256(ethers.toUtf8Bytes("sale-no-l1"));
    await vault.connect(binder).bindSale(opId, ethers.ZeroAddress, buyer.address, 1n, false);
    const [l0Pool, adminAmt, foundAmt, total] = await vault.previewSplit(1n);
    await token.connect(owner).mint(await vault.getAddress(), total);
    await vault
      .connect(owner)
      .onBridgeMint(opId, 8453n, await token.getAddress(), [await vault.getAddress()], [total]);
    expect(await token.balanceOf(foundation.address)).to.equal(foundAmt + l0Pool);
    expect(await token.balanceOf(owner.address)).to.equal(adminAmt);
  });

  it("rejects onBridgeMint from non-treasury", async function () {
    const { binder, buyer, other, vault, token } = await deployStack();
    const opId = ethers.keccak256(ethers.toUtf8Bytes("bad-caller"));
    await vault.connect(binder).bindSale(opId, ethers.ZeroAddress, buyer.address, 1n, false);
    await expect(
      vault
        .connect(other)
        .onBridgeMint(opId, 8453n, await token.getAddress(), [await vault.getAddress()], [1_370_000_000n]),
    ).to.be.revertedWithCustomError(vault, "Unauthorized");
  });

  it("testMode sends all to foundation", async function () {
    const { owner, binder, buyer, foundation, vault, token } = await deployStack();
    const opId = ethers.keccak256(ethers.toUtf8Bytes("test-sale"));
    await vault.connect(binder).bindSale(opId, ethers.ZeroAddress, buyer.address, 1n, true);
    const amount = 1_000_000n;
    await token.connect(owner).mint(await vault.getAddress(), amount);
    await vault
      .connect(owner)
      .onBridgeMint(opId, 8453n, await token.getAddress(), [await vault.getAddress()], [amount]);
    expect(await token.balanceOf(foundation.address)).to.equal(amount);
  });

  it("L0 can update child L1 ratioBps", async function () {
    const { owner, l0User, l1User, vault } = await deployStack();
    await registerL0(vault, owner, l0User, "beamio-genesis-l0-ratio");
    await registerL1(vault, l0User, l1User, "beamio-genesis-l1-ratio", 3000n);
    await vault.connect(l0User).setL1Ratio(l1User.address, 5500n);
    expect((await vault.members(l1User.address)).ratioBps).to.equal(5500n);
  });
});
