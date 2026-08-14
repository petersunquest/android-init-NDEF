import { expect } from "chai";
import fc from "fast-check";
import { deployGatewayFixture, ethers } from "./fixtures.js";

describe("AssetBurnMintGateway TLA+ state-machine properties", function () {
  this.timeout(600_000);

  it("preserves strong conservation through randomized burn/activate/refund traces", async function () {
    await fc.assert(
      fc.asyncProperty(
        fc.array(
          fc.record({
            units: fc.integer({ min: 1, max: 20 }),
            activate: fc.boolean(),
          }),
          { minLength: 1, maxLength: 5 },
        ),
        async (steps) => {
          const fixture = await deployGatewayFixture();
          const receipts: Array<{
            id: string;
            activate: boolean;
            amount: bigint;
          }> = [];
          let latestDeadline = 0;

          for (const [index, step] of steps.entries()) {
            const block = await ethers.provider.getBlock("latest");
            if (!block) throw new Error("missing block");
            const deadline = block.timestamp + 600 + index;
            latestDeadline = Math.max(latestDeadline, deadline);
            const amount = ethers.parseEther(String(step.units));
            const id = await fixture.gateway
              .connect(fixture.user)
              .burnToDle.staticCall(
                fixture.tokenId,
                await fixture.token.getAddress(),
                amount,
                deadline,
              );
            await fixture.gateway
              .connect(fixture.user)
              .burnToDle(
                fixture.tokenId,
                await fixture.token.getAddress(),
                amount,
                deadline,
              );
            receipts.push({ id, activate: step.activate, amount });
            if (step.activate) {
              const ac = await fixture.nextArchiveCertificate(fixture.tokenId);
              await fixture.gateway.activateBurn(
                id,
                ac.certificate,
                ac.signatures,
              );
            }
            await assertAccountingInvariant(fixture);
          }

          await increaseTo(latestDeadline + 1);
          for (const receipt of receipts) {
            if (receipt.activate) {
              await expect(
                fixture.gateway.refundBurn(receipt.id),
              ).to.be.revertedWithCustomError(
                fixture.gateway,
                "InvalidReceiptState",
              );
            } else {
              await fixture.gateway.refundBurn(receipt.id);
              const ac = await fixture.nextArchiveCertificate(fixture.tokenId);
              await expect(
                fixture.gateway.activateBurn(
                  receipt.id,
                  ac.certificate,
                  ac.signatures,
                ),
              ).to.be.revertedWithCustomError(
                fixture.gateway,
                "InvalidReceiptState",
              );
            }
            await assertAccountingInvariant(fixture);
          }

          const accounting = await fixture.gateway.assetAccounting(
            await fixture.token.getAddress(),
          );
          const expectedActivated = receipts
            .filter((row) => row.activate)
            .reduce((sum, row) => sum + row.amount, 0n);
          expect(accounting.l2CreditLiability).to.equal(expectedActivated);
          expect(accounting.pendingBurnLiability).to.equal(0);
        },
      ),
      { numRuns: 5 },
    );
  });

  it("keeps reservations bounded and consumes one credit through normal or force exit", async function () {
    await fc.assert(
      fc.asyncProperty(
        fc.record({
          normalUnits: fc.integer({ min: 1, max: 25 }),
          forceUnits: fc.integer({ min: 1, max: 25 }),
        }),
        async ({ normalUnits, forceUnits }) => {
          const fixture = await deployGatewayFixture();
          const total = BigInt(normalUnits + forceUnits);
          await burnAndActivate(fixture, ethers.parseEther(total.toString()));
          const asset = await fixture.token.getAddress();

          const normalAc = await fixture.nextArchiveCertificate(fixture.tokenId);
          const normalAmount = ethers.parseEther(String(normalUnits));
          const normalId = await fixture.gateway
            .connect(fixture.user)
            .requestNormalExit.staticCall(
              fixture.tokenId,
              asset,
              1,
              normalAmount,
              normalAc.certificate,
              normalAc.signatures,
            );
          await fixture.gateway
            .connect(fixture.user)
            .requestNormalExit(
              fixture.tokenId,
              asset,
              1,
              normalAmount,
              normalAc.certificate,
              normalAc.signatures,
            );
          expect(
            await fixture.gateway.reservedExitCredit(
              fixture.tokenId,
              asset,
              1,
            ),
          ).to.equal(normalAmount);
          await fixture.gateway.finalizeNormalExit(normalId);

          const forceAc = await fixture.nextArchiveCertificate(fixture.tokenId);
          const forceAmount = ethers.parseEther(String(forceUnits));
          const forceId = await fixture.gateway
            .connect(fixture.user)
            .requestForceExit.staticCall(
              fixture.tokenId,
              asset,
              1,
              forceAmount,
              1,
              forceAc.certificate,
              forceAc.signatures,
            );
          await fixture.gateway
            .connect(fixture.user)
            .requestForceExit(
              fixture.tokenId,
              asset,
              1,
              forceAmount,
              1,
              forceAc.certificate,
              forceAc.signatures,
            );
          await expect(
            fixture.gateway
              .connect(fixture.user)
              .requestForceExit(
                fixture.tokenId,
                asset,
                1,
                forceAmount,
                1,
                forceAc.certificate,
                forceAc.signatures,
              ),
          ).to.be.revertedWithCustomError(
            fixture.gateway,
            "ForceExitAlreadyPending",
          );

          const requestBlock = await ethers.provider.getBlock("latest");
          if (!requestBlock) throw new Error("missing request block");
          const observedAc = await fixture.nextArchiveCertificate(
            fixture.tokenId,
            {
              l1ContextBlockNumber: BigInt(requestBlock.number),
              l1ContextBlockHash: requestBlock.hash,
            },
          );
          await fixture.gateway.refreshForceExitProof(
            forceId,
            forceAmount,
            observedAc.certificate,
            observedAc.signatures,
          );

          await fixture.gateway.setPauseState(true, true, true, false);
          const right = await fixture.gateway.exitRights(forceId);
          await increaseTo(Number(right.challengeDeadline) + 1);
          await fixture.gateway.finalizeForceExit(forceId);

          expect(
            await fixture.gateway.tipCredit(fixture.tokenId, asset, 1),
          ).to.equal(0);
          expect(
            await fixture.gateway.reservedExitCredit(
              fixture.tokenId,
              asset,
              1,
            ),
          ).to.equal(0);
          await assertAccountingInvariant(fixture);
        },
      ),
      { numRuns: 5 },
    );
  });

  it("rejects stale ACs, ordinary actions under pause/oracle failure, and burns beyond capacity", async function () {
    const fixture = await deployGatewayFixture();
    const asset = await fixture.token.getAddress();
    const activated = await burnAndActivate(fixture, ethers.parseEther("10"));
    const newerAc = await fixture.nextArchiveCertificate(fixture.tokenId);
    await fixture.gateway
      .connect(fixture.user)
      .requestNormalExit(
        fixture.tokenId,
        asset,
        1,
        ethers.parseEther("1"),
        newerAc.certificate,
        newerAc.signatures,
      );

    await expect(
      fixture.gateway
        .connect(fixture.user)
        .requestNormalExit(
          fixture.tokenId,
          asset,
          1,
          ethers.parseEther("1"),
          activated.ac.certificate,
          activated.ac.signatures,
        ),
    ).to.be.revertedWithCustomError(
      fixture.gateway,
      "StaleArchiveCertificate",
    );

    await fixture.gateway.setPauseState(true, true, true, false);
    const block = await ethers.provider.getBlock("latest");
    if (!block) throw new Error("missing block");
    await expect(
      fixture.gateway
        .connect(fixture.user)
        .burnToDle(
          fixture.tokenId,
          asset,
          ethers.parseEther("1"),
          block.timestamp + 100,
        ),
    ).to.be.revertedWithCustomError(fixture.gateway, "IngressPaused");
    await expect(
      fixture.gateway
        .connect(fixture.user)
        .requestNormalExit(
          fixture.tokenId,
          asset,
          1,
          ethers.parseEther("1"),
          newerAc.certificate,
          newerAc.signatures,
        ),
    ).to.be.revertedWithCustomError(
      fixture.gateway,
      "OrdinaryActionPaused",
    );

    await fixture.gateway.setPauseState(false, false, false, true);
    await fixture.treasury.configureAsset(asset, ethers.parseEther("10"));
    await expect(
      fixture.gateway
        .connect(fixture.user)
        .burnToDle(
          fixture.tokenId,
          asset,
          ethers.parseEther("1"),
          block.timestamp + 1000,
        ),
    ).to.be.revertedWithCustomError(fixture.gateway, "CapacityExceeded");
  });

  it("rolls back terminal state on Treasury mint revert and permits exact retry", async function () {
    const fixture = await deployGatewayFixture();
    const asset = await fixture.token.getAddress();
    const { id } = await burnPending(fixture, ethers.parseEther("8"), 60);
    const receipt = await fixture.gateway.burnReceipts(id);
    await increaseTo(Number(receipt.deadline) + 1);

    await fixture.treasury.setFailMint(true);
    await expect(fixture.gateway.refundBurn(id)).to.be.revertedWithCustomError(
      fixture.treasury,
      "MockMintFailure",
    );
    expect((await fixture.gateway.burnReceipts(id)).status).to.equal(1);
    await assertAccountingInvariant(fixture);

    await expect(
      setMockAdmissionPolicy(fixture, 2),
    ).to.be.revertedWithCustomError(
      fixture.admission,
      "OutstandingLiability",
    );
    await fixture.treasury.setFailMint(false);
    await fixture.gateway.refundBurn(id);
    await setMockAdmissionPolicy(fixture, 2);
    expect((await fixture.gateway.burnReceipts(id)).status).to.equal(3);
    expect(await fixture.token.balanceOf(await fixture.user.getAddress())).to.equal(
      ethers.parseEther("10000"),
    );
    expect(await fixture.treasury.reservedReplacement(asset)).to.equal(0);
    await assertAccountingInvariant(fixture);

    await burnAndActivate(fixture, ethers.parseEther("4"));
    const exitAc = await fixture.nextArchiveCertificate(fixture.tokenId);
    const exitId = await fixture.gateway
      .connect(fixture.user)
      .requestNormalExit.staticCall(
        fixture.tokenId,
        asset,
        2,
        ethers.parseEther("4"),
        exitAc.certificate,
        exitAc.signatures,
      );
    await fixture.gateway
      .connect(fixture.user)
      .requestNormalExit(
        fixture.tokenId,
        asset,
        2,
        ethers.parseEther("4"),
        exitAc.certificate,
        exitAc.signatures,
      );
    await fixture.treasury.setFailMint(true);
    await expect(
      fixture.gateway.finalizeNormalExit(exitId),
    ).to.be.revertedWithCustomError(fixture.treasury, "MockMintFailure");
    expect((await fixture.gateway.exitRights(exitId)).status).to.equal(1);
    expect(
      await fixture.gateway.reservedExitCredit(fixture.tokenId, asset, 2),
    ).to.equal(ethers.parseEther("4"));
    await assertAccountingInvariant(fixture);

    await fixture.treasury.setFailMint(false);
    await fixture.gateway.finalizeNormalExit(exitId);
    expect((await fixture.gateway.exitRights(exitId)).status).to.equal(4);
    expect(await fixture.token.balanceOf(await fixture.user.getAddress())).to.equal(
      ethers.parseEther("10000"),
    );
    await assertAccountingInvariant(fixture);
  });
});

async function burnPending(
  fixture: Awaited<ReturnType<typeof deployGatewayFixture>>,
  amount: bigint,
  lifetime = 600,
) {
  const block = await ethers.provider.getBlock("latest");
  if (!block) throw new Error("missing block");
  const deadline = block.timestamp + lifetime;
  const id = await fixture.gateway
    .connect(fixture.user)
    .burnToDle.staticCall(
      fixture.tokenId,
      await fixture.token.getAddress(),
      amount,
      deadline,
    );
  await fixture.gateway
    .connect(fixture.user)
    .burnToDle(
      fixture.tokenId,
      await fixture.token.getAddress(),
      amount,
      deadline,
    );
  return { id, deadline };
}

async function burnAndActivate(
  fixture: Awaited<ReturnType<typeof deployGatewayFixture>>,
  amount: bigint,
) {
  const pending = await burnPending(fixture, amount);
  const ac = await fixture.nextArchiveCertificate(fixture.tokenId);
  await fixture.gateway.activateBurn(pending.id, ac.certificate, ac.signatures);
  await assertAccountingInvariant(fixture);
  return { ...pending, ac };
}

async function assertAccountingInvariant(
  fixture: Awaited<ReturnType<typeof deployGatewayFixture>>,
) {
  const asset = await fixture.token.getAddress();
  const accounting = await fixture.gateway.assetAccounting(asset);
  expect(accounting.physicalBurned).to.equal(
    accounting.pendingBurnLiability +
      accounting.l2CreditLiability +
      accounting.refundedPending +
      accounting.mintedExit,
  );
  expect(accounting.reservedReplacement).to.equal(
    accounting.pendingBurnLiability + accounting.l2CreditLiability,
  );
  expect(await fixture.gateway.accountingInvariantHolds(asset)).to.equal(true);
  expect(await fixture.treasury.reservedReplacement(asset)).to.equal(
    accounting.reservedReplacement,
  );
}

async function increaseTo(timestamp: number) {
  const block = await ethers.provider.getBlock("latest");
  if (!block) throw new Error("missing block");
  if (block.timestamp < timestamp) {
    await ethers.provider.send("evm_increaseTime", [timestamp - block.timestamp]);
  }
  await ethers.provider.send("evm_mine", []);
}

async function setMockAdmissionPolicy(
  fixture: Awaited<ReturnType<typeof deployGatewayFixture>>,
  adapterEpoch: number,
) {
  return fixture.admission.setAssetPolicy(
    await fixture.token.getAddress(),
    await fixture.treasury.getAddress(),
    await fixture.oracle.getAddress(),
    ethers.ZeroHash,
    ethers.ZeroHash,
    ethers.id("mock-mint-authority-proof"),
    adapterEpoch,
    3600,
    1_000_000,
    100_000_000,
    ethers.parseEther("1000000"),
    1,
  );
}
