import { expect } from "chai";
import { deployAuctionFixture } from "./fixtures.js";

describe("DLE mock-L1 auction fixture", function () {
  it("mints and binds ASSET / STORAGE / TRADE chain NFTs on local registry", async function () {
    const fx = await deployAuctionFixture();
    for (const classId of [1, 2, 3] as const) {
      const { tokenId, genesisAcHash } = await fx.mintAndBindClass(classId);
      expect(await fx.chainRegistry.balanceOf(await fx.user.getAddress(), tokenId)).to.equal(1n);
      expect(await fx.chainRegistry.chainClass(tokenId)).to.equal(classId);
      expect(await fx.chainRegistry.chainOwner(tokenId)).to.equal(await fx.user.getAddress());
      // Public struct getter — status is AssignmentStatus.BOUND (2)
      const assignment = await fx.chainRegistry.assignments(tokenId);
      expect(assignment.status).to.equal(2n);
      expect(await fx.chainRegistry.genesisAcHash(tokenId)).to.equal(genesisAcHash);
    }
    expect(await fx.settlement.certificateAuthority()).to.equal(await fx.authority.getAddress());
    expect(await fx.quote.symbol()).to.equal("MAQ");
  });
});
