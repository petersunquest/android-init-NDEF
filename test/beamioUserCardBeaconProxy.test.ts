import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

const IMPL_OWNER_SENTINEL = "0x000000000000000000000000000000000000dEaD";
const METADATA_URI = "https://beamio.app/api/metadata/0x";
const PRICE_E6 = 1_000_000n;
const INITIAL_TOPUP_TIER_CONFIG = ethers.AbiCoder.defaultAbiCoder().encode(
  ["tuple(uint8 qualificationMode,tuple(uint256 minUsdc6,uint256 attr,uint256 tierExpirySeconds,bool upgradeByBalance)[] tiers,uint256[] membershipFeeE6,uint8[] membershipDurationKind)"],
  [[0, [[PRICE_E6, 0n, 0n, false]], [], []]],
);
const DIRECT_MEMBERSHIP_TIER_CONFIG = ethers.AbiCoder.defaultAbiCoder().encode(
  ["tuple(uint8 qualificationMode,tuple(uint256 minUsdc6,uint256 attr,uint256 tierExpirySeconds,bool upgradeByBalance)[] tiers,uint256[] membershipFeeE6,uint8[] membershipDurationKind)"],
  [[1, [[1n, 0n, 0n, false], [2n, 1n, 0n, false]], [990_000n, 9_990_000n], [3, 3]]],
);
const MEMBERSHIP_FEE_STORAGE_SLOT = ethers.id("beamio.usercard.membership.fee.storage.v1");

function membershipFeeSlot(index: bigint): string {
  return ethers.keccak256(
    ethers.concat([
      ethers.zeroPadValue(ethers.toBeHex(index), 32),
      MEMBERSHIP_FEE_STORAGE_SLOT,
    ]),
  );
}

async function deployLinkedUserCardFactory() {
  const formatting = await ethers.deployContract("BeamioUserCardFormattingLib");
  await formatting.waitForDeployment();
  const transfer = await ethers.deployContract("BeamioUserCardTransferLib");
  await transfer.waitForDeployment();
  const views = await ethers.deployContract("BeamioUserCardViewsLib");
  await views.waitForDeployment();
  const gatewayMint = await ethers.deployContract("BeamioUserCardGatewayMintLib");
  await gatewayMint.waitForDeployment();
  const moduleRouter = await ethers.deployContract("BeamioUserCardModuleRouterLib");
  await moduleRouter.waitForDeployment();
  const adminGateway = await ethers.deployContract("BeamioUserCardAdminGatewayLib");
  await adminGateway.waitForDeployment();
  const redeemGateway = await ethers.deployContract("BeamioUserCardRedeemGatewayLib");
  await redeemGateway.waitForDeployment();
  const membershipFeeOps = await ethers.deployContract("MembershipFeeOpsLib");
  await membershipFeeOps.waitForDeployment();
  const tierOpsFactory = await ethers.getContractFactory("BeamioUserCardTierOpsLib", {
    libraries: { MembershipFeeOpsLib: await membershipFeeOps.getAddress() },
  });
  const tierOps = await tierOpsFactory.deploy();
  await tierOps.waitForDeployment();
  const referrerRegistry = await ethers.deployContract("ReferrerRegistryLib");
  await referrerRegistry.waitForDeployment();
  const referrerFactory = await ethers.getContractFactory("BeamioUserCardReferrerLib", {
    libraries: { ReferrerRegistryLib: await referrerRegistry.getAddress() },
  });
  const referrer = await referrerFactory.deploy();
  await referrer.waitForDeployment();
  const updateFactory = await ethers.getContractFactory("BeamioUserCardUpdateLib", {
    libraries: {
      BeamioUserCardReferrerLib: await referrer.getAddress(),
      BeamioUserCardTransferLib: await transfer.getAddress(),
    },
  });
  const update = await updateFactory.deploy();
  await update.waitForDeployment();

  const libraries = {
    BeamioUserCardAdminGatewayLib: await adminGateway.getAddress(),
    BeamioUserCardFormattingLib: await formatting.getAddress(),
    BeamioUserCardGatewayMintLib: await gatewayMint.getAddress(),
    BeamioUserCardModuleRouterLib: await moduleRouter.getAddress(),
    BeamioUserCardRedeemGatewayLib: await redeemGateway.getAddress(),
    BeamioUserCardTierOpsLib: await tierOps.getAddress(),
    BeamioUserCardTransferLib: await transfer.getAddress(),
    BeamioUserCardUpdateLib: await update.getAddress(),
    BeamioUserCardViewsLib: await views.getAddress(),
  };
  const factory = await ethers.getContractFactory("BeamioUserCard", { libraries });
  return { factory, formatting };
}

describe("BeamioUserCard BeaconProxy", function () {
  this.timeout(180_000);

  it("initializes a BeaconProxy card and locks CREATE plus the logic impl", async function () {
    const [owner] = await ethers.getSigners();
    const ownerAddr = await owner.getAddress();
    const { factory, formatting } = await deployLinkedUserCardFactory();
    const dummyGateway = await formatting.getAddress();

    const impl = await factory.deploy("", 0, 0n, ethers.ZeroAddress, ethers.ZeroAddress);
    await impl.waitForDeployment();
    expect(await impl.owner()).to.equal(IMPL_OWNER_SENTINEL);
    expect(await impl.VERSION()).to.equal(20n);

    const beacon = await ethers.deployContract("BeamioUserCardUpgradeableBeacon", [
      await impl.getAddress(),
      ownerAddr,
    ]);
    await beacon.waitForDeployment();

    const initData = impl.interface.encodeFunctionData("initialize", [
      METADATA_URI,
      0,
      PRICE_E6,
      ownerAddr,
      dummyGateway,
      INITIAL_TOPUP_TIER_CONFIG,
    ]);
    const proxy = await ethers.deployContract("BeamioUserCardBeaconProxy", [
      await beacon.getAddress(),
      initData,
    ]);
    await proxy.waitForDeployment();

    const card = factory.attach(await proxy.getAddress());
    expect(await card.VERSION()).to.equal(20n);
    expect(await card.owner()).to.equal(ownerAddr);
    expect(await card.factoryGateway()).to.equal(dummyGateway);
    expect(await card.currency()).to.equal(0n);
    expect(await card.pointsUnitPriceInCurrencyE6()).to.equal(PRICE_E6);
    expect((await card.tiers(0)).minUsdc6).to.equal(PRICE_E6);

    await expect(card.initialize("x", 0, 1n, ownerAddr, dummyGateway, "0x")).to.be.revertedWithCustomError(
      card,
      "UC_AlreadyInitialized",
    );

    const createCard = await factory.deploy(METADATA_URI, 0, PRICE_E6, ownerAddr, dummyGateway);
    await createCard.waitForDeployment();
    await expect(
      createCard.initialize("x", 0, 1n, ownerAddr, dummyGateway, "0x"),
    ).to.be.revertedWithCustomError(createCard, "UC_AlreadyInitialized");
  });

  it("keeps initialized storage after beacon.upgradeTo", async function () {
    const [owner] = await ethers.getSigners();
    const ownerAddr = await owner.getAddress();
    const { factory, formatting } = await deployLinkedUserCardFactory();
    const dummyGateway = await formatting.getAddress();

    const impl1 = await factory.deploy("", 0, 0n, ethers.ZeroAddress, ethers.ZeroAddress);
    await impl1.waitForDeployment();
    const beacon = await ethers.deployContract("BeamioUserCardUpgradeableBeacon", [
      await impl1.getAddress(),
      ownerAddr,
    ]);
    await beacon.waitForDeployment();

    const initData = impl1.interface.encodeFunctionData("initialize", [
      METADATA_URI,
      0,
      PRICE_E6,
      ownerAddr,
      dummyGateway,
      INITIAL_TOPUP_TIER_CONFIG,
    ]);
    const proxy = await ethers.deployContract("BeamioUserCardBeaconProxy", [
      await beacon.getAddress(),
      initData,
    ]);
    await proxy.waitForDeployment();
    const card = factory.attach(await proxy.getAddress());

    const impl2 = await factory.deploy("", 0, 0n, ethers.ZeroAddress, ethers.ZeroAddress);
    await impl2.waitForDeployment();
    const impl2Addr = await impl2.getAddress();
    expect(impl2Addr).to.not.equal(await impl1.getAddress());

    await (await beacon.upgradeTo(impl2Addr)).wait();
    expect(await beacon.implementation()).to.equal(impl2Addr);
    expect(await card.VERSION()).to.equal(20n);
    expect(await card.owner()).to.equal(ownerAddr);
    expect(await card.factoryGateway()).to.equal(dummyGateway);
    expect(await card.currency()).to.equal(0n);
    expect(await card.pointsUnitPriceInCurrencyE6()).to.equal(PRICE_E6);
  });

  it("atomically stores direct-membership base and higher tiers in the proxy initializer", async function () {
    const [owner] = await ethers.getSigners();
    const ownerAddr = await owner.getAddress();
    const { factory, formatting } = await deployLinkedUserCardFactory();
    const impl = await factory.deploy("", 0, 0n, ethers.ZeroAddress, ethers.ZeroAddress);
    await impl.waitForDeployment();
    const beacon = await ethers.deployContract("BeamioUserCardUpgradeableBeacon", [
      await impl.getAddress(),
      ownerAddr,
    ]);
    await beacon.waitForDeployment();

    const initData = impl.interface.encodeFunctionData("initialize", [
      METADATA_URI,
      0,
      PRICE_E6,
      ownerAddr,
      await formatting.getAddress(),
      DIRECT_MEMBERSHIP_TIER_CONFIG,
    ]);
    const proxy = await ethers.deployContract("BeamioUserCardBeaconProxy", [
      await beacon.getAddress(),
      initData,
    ]);
    await proxy.waitForDeployment();
    const card = factory.attach(await proxy.getAddress());

    expect((await card.tiers(0)).minUsdc6).to.equal(1n);
    expect((await card.tiers(1)).minUsdc6).to.equal(2n);
    expect(BigInt(await ethers.provider.getStorage(await proxy.getAddress(), membershipFeeSlot(0n)))).to.equal(990_000n);
    expect(BigInt(await ethers.provider.getStorage(await proxy.getAddress(), membershipFeeSlot(1n)))).to.equal(9_990_000n);
  });
});
