import { expect } from "chai";
import { deployProxy, ethers } from "./fixtures.js";

describe("GlobalArchiveRoutingRegistryV1", function () {
  this.timeout(120_000);

  it("registers seven unique participant wallets and exposes §5.2.0d views", async function () {
    const signers = await ethers.getSigners();
    const [owner, ...rest] = signers;
    const active = rest.slice(0, 5);
    const standby = rest.slice(5, 7);
    const registry = await deployProxy("GlobalArchiveRoutingRegistryV1", [await owner.getAddress()]);

    const activeAddresses = await Promise.all(active.map((signer) => signer.getAddress()));
    const standbyAddresses = await Promise.all(standby.map((signer) => signer.getAddress()));
    await registry.registerLiveGroup(
      activeAddresses,
      standbyAddresses,
      ethers.id("group-key"),
      ethers.id("membership-root"),
      ethers.id("standby-root"),
      1,
    );

    expect(await registry.liveGroupIds()).to.deep.equal([1n]);
    const archives = await registry.archivesOf(1);
    expect(archives).to.deep.equal([...activeAddresses, ...standbyAddresses]);
    expect(await registry.chainsOf(1)).to.deep.equal([]);

    await registry.bindChain(42, 1);
    expect(await registry.route(42)).to.equal(1n);
    expect(await registry.chainsOf(1)).to.deep.equal([42n]);
    expect(await registry.historyProviders(42)).to.deep.equal(archives);
  });
});
