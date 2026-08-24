import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

const IMPL_OWNER_SENTINEL = "0x000000000000000000000000000000000000dEaD";
const METADATA_URI = "https://beamio.app/api/metadata/0x";
const PRICE_E6 = 1_000_000n;

async function deployLinkedUserCardFactory() {
  const formatting = await ethers.deployContract("BeamioUserCardFormattingLib");
  await formatting.waitForDeployment();
  const transfer = await ethers.deployContract("BeamioUserCardTransferLib");
  await transfer.waitForDeployment();
  const views = await ethers.deployContract("BeamioUserCardViewsLib");
  await views.waitForDeployment();

  const libraries = {
    BeamioUserCardFormattingLib: await formatting.getAddress(),
    BeamioUserCardTransferLib: await transfer.getAddress(),
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
    expect(await impl.VERSION()).to.equal(14n);

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
    ]);
    const proxy = await ethers.deployContract("BeamioUserCardBeaconProxy", [
      await beacon.getAddress(),
      initData,
    ]);
    await proxy.waitForDeployment();

    const card = factory.attach(await proxy.getAddress());
    expect(await card.VERSION()).to.equal(14n);
    expect(await card.owner()).to.equal(ownerAddr);
    expect(await card.factoryGateway()).to.equal(dummyGateway);
    expect(await card.currency()).to.equal(0n);
    expect(await card.pointsUnitPriceInCurrencyE6()).to.equal(PRICE_E6);

    await expect(card.initialize("x", 0, 1n, ownerAddr, dummyGateway)).to.be.revertedWithCustomError(
      card,
      "UC_AlreadyInitialized",
    );

    const createCard = await factory.deploy(METADATA_URI, 0, PRICE_E6, ownerAddr, dummyGateway);
    await createCard.waitForDeployment();
    await expect(
      createCard.initialize("x", 0, 1n, ownerAddr, dummyGateway),
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
    expect(await card.VERSION()).to.equal(14n);
    expect(await card.owner()).to.equal(ownerAddr);
    expect(await card.factoryGateway()).to.equal(dummyGateway);
    expect(await card.currency()).to.equal(0n);
    expect(await card.pointsUnitPriceInCurrencyE6()).to.equal(PRICE_E6);
  });
});
