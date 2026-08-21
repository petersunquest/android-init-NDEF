import { expect } from "chai";
import { deployProxy, ethers } from "./fixtures.js";

describe("DLE mock-L1 certificate settlement", function () {
  it("escrows an ERC-721 and atomically applies the 1 bps 50/50 fee split", async function () {
    const [authority, seller, buyer, scanner, committeeOne, committeeTwo] =
      await ethers.getSigners();
    const quote = await deployProxy("MockCanonicalAsset", [
      await authority.getAddress(),
      "Mock quote",
      "MQUOTE",
    ]);
    const nft = await ethers.deployContract("MockDleAuctionNft");
    const settlement = await ethers.deployContract("MockDleAuctionSettlement", [
      await authority.getAddress(),
    ]);
    await Promise.all([
      nft.waitForDeployment(),
      settlement.waitForDeployment(),
    ]);

    const tokenId = await nft.mint.staticCall(await seller.getAddress());
    await nft.mint(await seller.getAddress());
    const ask = 1_000_000n;
    const orderHash = ethers.id("mock-l1-order:1");
    const deadline = BigInt((await ethers.provider.getBlock("latest"))!.timestamp + 3600);
    await nft.connect(seller).approve(await settlement.getAddress(), tokenId);
    await settlement
      .connect(seller)
      .list(
        orderHash,
        await nft.getAddress(),
        tokenId,
        await quote.getAddress(),
        ask,
        deadline,
      );

    await quote.mint(await buyer.getAddress(), ask);
    await quote.connect(buyer).approve(await settlement.getAddress(), ask);
    const certificateHash = ethers.id("mock-l1-trade-certificate:1");
    await settlement.settle(
      certificateHash,
      orderHash,
      await buyer.getAddress(),
      ask,
      await scanner.getAddress(),
      [await committeeOne.getAddress(), await committeeTwo.getAddress()],
    );

    expect(await nft.ownerOf(tokenId)).to.equal(await buyer.getAddress());
    expect(await quote.balanceOf(await seller.getAddress())).to.equal(999_900n);
    expect(await quote.balanceOf(await scanner.getAddress())).to.equal(50n);
    expect(await quote.balanceOf(await committeeOne.getAddress())).to.equal(25n);
    expect(await quote.balanceOf(await committeeTwo.getAddress())).to.equal(25n);
    expect(await settlement.settledCertificate(certificateHash)).to.equal(true);
    await expect(
      settlement.settle(
        certificateHash,
        orderHash,
        await buyer.getAddress(),
        ask,
        await scanner.getAddress(),
        [await committeeOne.getAddress()],
      ),
    ).to.be.revertedWithCustomError(settlement, "CertificateAlreadySettled");
  });
});
