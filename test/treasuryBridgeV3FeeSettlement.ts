import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("TreasuryBridgeV3 fee settlement mint", function () {
  async function deployStack() {
    const [admin, airdrop, user] = await ethers.getSigners();

    const usdcImpl = await (await ethers.getContractFactory("TreasuryCanonicalERC20V3")).deploy();
    await usdcImpl.waitForDeployment();
    const usdcInit = usdcImpl.interface.encodeFunctionData("initialize", [
      "USD Coin",
      "USDC",
      6,
      admin.address,
      admin.address, // temporary bridge role holder; replaced by bridge proxy
      "https://mainnet.conet.network/usdc/metadata.json",
    ]);
    const usdcProxy = await (
      await ethers.getContractFactory("TreasuryV3ERC1967Proxy")
    ).deploy(await usdcImpl.getAddress(), usdcInit);
    await usdcProxy.waitForDeployment();
    const usdc = await ethers.getContractAt(
      "TreasuryCanonicalERC20V3",
      await usdcProxy.getAddress(),
    );

    const bridgeImpl = await (await ethers.getContractFactory("TreasuryBridgeV3")).deploy();
    await bridgeImpl.waitForDeployment();
    const bridgeInit = bridgeImpl.interface.encodeFunctionData("initialize", [
      admin.address,
      [admin.address],
    ]);
    const bridgeProxy = await (
      await ethers.getContractFactory("TreasuryV3ERC1967Proxy")
    ).deploy(await bridgeImpl.getAddress(), bridgeInit);
    await bridgeProxy.waitForDeployment();
    const bridge = await ethers.getContractAt(
      "TreasuryBridgeV3",
      await bridgeProxy.getAddress(),
    );

    const treasuryRole = await usdc.TREASURY_ROLE();
    await usdc.connect(admin).grantRole(treasuryRole, await bridge.getAddress());
    await bridge.connect(admin).setFeeSettlement(airdrop.address, await usdc.getAddress());

    return { admin, airdrop, user, usdc, bridge };
  }

  it("mints V3 USDC via mintForAdmin only for feeSettlement", async function () {
    const { admin, airdrop, user, usdc, bridge } = await deployStack();
    const amount = 1_000_000n; // 1 USDC (6 decimals)

    await expect(
      bridge.connect(admin).mintForAdmin(await usdc.getAddress(), user.address, amount),
    ).to.be.revertedWithCustomError(bridge, "NotFeeSettlement");

    await expect(
      bridge.connect(airdrop).mintForAdmin(user.address, user.address, amount),
    ).to.be.revertedWithCustomError(bridge, "InvalidPolicy");

    await bridge.connect(airdrop).mintForAdmin(await usdc.getAddress(), user.address, amount);
    expect(await usdc.balanceOf(user.address)).to.equal(amount);
    expect(await usdc.totalSupply()).to.equal(amount);
  });
});
