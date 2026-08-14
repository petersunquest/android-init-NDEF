import { expect } from "chai";
import fc from "fast-check";
import {
  deployArchiveFixture,
  deployGatewayFixture,
  deployProxy,
  ethers,
  signSorted,
} from "./fixtures.js";

describe("CoNET-DLE infrastructure properties", function () {
  this.timeout(240_000);

  it("L1QueueAccumulatorV1 preserves canonical order, root determinism and duplicate rejection", async function () {
    await fc.assert(
      fc.asyncProperty(
        fc.uniqueArray(fc.uint8Array({ minLength: 1, maxLength: 32 }), {
          minLength: 1,
          maxLength: 18,
          selector: (bytes) => Buffer.from(bytes).toString("hex"),
        }),
        async (rawCommitments) => {
          const [owner] = await ethers.getSigners();
          const queue = await deployProxy("L1QueueAccumulatorV1", [
            await owner.getAddress(),
          ]);
          const commitments = rawCommitments.map((bytes) =>
            ethers.keccak256(bytes),
          );
          let expectedRoot = emptyAccumulatorRoot();
          const frontier = Array<string>(32).fill(ethers.ZeroHash);

          for (let seq = 0; seq < commitments.length; seq += 1) {
            await queue.enqueue(commitments[seq]);
            expectedRoot = insertAccumulator(
              BigInt(seq),
              commitments[seq],
              frontier,
            );
            expect(await queue.requestCommitmentBySeq(seq)).to.equal(
              commitments[seq],
            );
            expect(await queue.queueAccumulatorRoot()).to.equal(expectedRoot);
          }

          await expect(queue.enqueue(commitments[0])).to.be.revertedWithCustomError(
            queue,
            "DuplicateCommitment",
          );
          const block = await ethers.provider.getBlock("latest");
          if (!block) throw new Error("missing block");
          await queue.freezeUnassignedRange(
            block.number + 100,
            ethers.id("groups"),
            ethers.id("uniform-v1"),
          );
          const checkpoint = await queue.rangeCheckpoints(1);
          expect(checkpoint.fromSeq).to.equal(0);
          expect(checkpoint.toSeq).to.equal(commitments.length - 1);
          expect(checkpoint.queueAccumulatorRoot).to.equal(expectedRoot);
          await expect(
            queue.freezeUnassignedRange(
              block.number + 101,
              ethers.id("groups"),
              ethers.id("uniform-v1"),
            ),
          ).to.be.revertedWithCustomError(queue, "PreviousRangeNotProcessed");
          await queue.markProcessedThrough(commitments.length - 1);
          expect(await queue.nextUnassignedSeq()).to.equal(commitments.length);
        },
      ),
      { numRuns: 6 },
    );
  });

  it("Operator/Group registries fail closed on duplicate domains and assignments", async function () {
    const fixture = await deployArchiveFixture();
    const duplicated = [...fixture.operatorIds];
    duplicated[6] = duplicated[0];
    const [decision, reason] =
      await fixture.operatorRegistry.evaluateCandidateSet(duplicated, true);
    expect(decision).to.equal(2);
    expect(reason).to.equal(ethers.id("DLE_OPERATOR_DUPLICATE"));

    const secondToken = await fixture.chainRegistry
      .connect(fixture.user)
      .mintChain.staticCall(await fixture.user.getAddress(), 1);
    await fixture.chainRegistry
      .connect(fixture.user)
      .mintChain(await fixture.user.getAddress(), 1);
    const block = await ethers.provider.getBlock("latest");
    if (!block) throw new Error("missing block");
    await fixture.chainRegistry.reserveArchiveGroup(
      secondToken,
      ethers.id("second-request"),
      ethers.id("shared-assignment"),
      1,
      fixture.groupKeyHash,
      1,
      fixture.membershipRoot,
      fixture.standbyRoot,
      block.timestamp + 1000,
    );

    const thirdToken = await fixture.chainRegistry
      .connect(fixture.user)
      .mintChain.staticCall(await fixture.user.getAddress(), 1);
    await fixture.chainRegistry
      .connect(fixture.user)
      .mintChain(await fixture.user.getAddress(), 1);
    await expect(
      fixture.chainRegistry.reserveArchiveGroup(
        thirdToken,
        ethers.id("third-request"),
        ethers.id("shared-assignment"),
        1,
        fixture.groupKeyHash,
        1,
        fixture.membershipRoot,
        fixture.standbyRoot,
        block.timestamp + 1000,
      ),
    ).to.be.revertedWithCustomError(
      fixture.chainRegistry,
      "DuplicateAssignmentId",
    );

      await fixture.chainRegistry
        .connect(fixture.user)
        .safeTransferFrom(
          await fixture.user.getAddress(),
          await fixture.relayer.getAddress(),
          secondToken,
          1,
          "0x",
        );
      expect(await fixture.chainRegistry.chainOwner(secondToken)).to.equal(
        await fixture.relayer.getAddress(),
      );
  });

  it("ArchiveCertificateVerifierV1 accepts exactly sorted 4-of-5 and rejects malformed quorums", async function () {
    const fixture = await deployArchiveFixture();
    const certificate = {
      archiveGroupId: 1,
      membershipEpoch: 1,
      keyEpoch: 1,
      chainNftId: 7,
      tipHeight: 1,
      attemptNonce: 1,
      parentArchiveCertificateHash: ethers.ZeroHash,
      stateRoot: ethers.id("state"),
      daRoot: ethers.id("da"),
      membershipRoot: fixture.membershipRoot,
      l1ContextBlockNumber: 0,
      l1ContextBlockHash: ethers.ZeroHash,
    };
    const types = {
      ArchiveCertificateV1: [
        { name: "archiveGroupId", type: "uint64" },
        { name: "membershipEpoch", type: "uint64" },
        { name: "keyEpoch", type: "uint64" },
        { name: "chainNftId", type: "uint256" },
        { name: "tipHeight", type: "uint64" },
        { name: "attemptNonce", type: "uint64" },
        { name: "parentArchiveCertificateHash", type: "bytes32" },
        { name: "stateRoot", type: "bytes32" },
        { name: "daRoot", type: "bytes32" },
        { name: "membershipRoot", type: "bytes32" },
        { name: "l1ContextBlockNumber", type: "uint64" },
        { name: "l1ContextBlockHash", type: "bytes32" },
      ],
    };

    await fc.assert(
      fc.asyncProperty(
        fc.uniqueArray(fc.integer({ min: 0, max: 4 }), {
          minLength: 4,
          maxLength: 5,
        }),
        async (indices) => {
          const signers = indices.map((index) => fixture.active[index]);
          const signatures = await signSorted(
            signers,
            fixture.domain,
            types,
            certificate,
          );
          await fixture.verifier.verifyArchiveCertificate(
            certificate,
            signatures,
          );
        },
      ),
      { numRuns: 8 },
    );

    const three = await signSorted(
      fixture.active.slice(0, 3),
      fixture.domain,
      types,
      certificate,
    );
    await expect(
      fixture.verifier.verifyArchiveCertificate(certificate, three),
    ).to.be.revertedWithCustomError(fixture.verifier, "InsufficientQuorum");

    const sorted = await signSorted(
      fixture.active.slice(0, 4),
      fixture.domain,
      types,
      certificate,
    );
    await expect(
      fixture.verifier.verifyArchiveCertificate(certificate, [
        sorted[1],
        sorted[0],
        sorted[2],
        sorted[3],
      ]),
    ).to.be.revertedWithCustomError(
      fixture.verifier,
      "SignersNotStrictlySorted",
    );

    const block = await ethers.provider.getBlock("latest");
    if (!block) throw new Error("missing block");
    const placement = {
      tokenId: 1,
      requestId: ethers.id("placement-request"),
      assignmentId: ethers.id("placement-assignment"),
      attemptNonce: 1,
      groupId: 1,
      groupKeyHash: fixture.groupKeyHash,
      genesisAcHash: ethers.id("placement-genesis"),
      membershipEpoch: 1,
      membershipRoot: fixture.membershipRoot,
      deadline: block.timestamp + 3600,
    };
    const placementTypes = {
      PlacementCertificateV1: [
        { name: "tokenId", type: "uint256" },
        { name: "requestId", type: "bytes32" },
        { name: "assignmentId", type: "bytes32" },
        { name: "attemptNonce", type: "uint64" },
        { name: "groupId", type: "uint64" },
        { name: "groupKeyHash", type: "bytes32" },
        { name: "genesisAcHash", type: "bytes32" },
        { name: "membershipEpoch", type: "uint64" },
        { name: "membershipRoot", type: "bytes32" },
        { name: "deadline", type: "uint64" },
      ],
    };
    const placementSignatures = await signSorted(
      fixture.active.slice(0, 4),
      fixture.domain,
      placementTypes,
      placement,
    );
    await fixture.groupRegistry.rotateMembership(
      1,
      fixture.operatorIds,
      await Promise.all(fixture.active.map((signer) => signer.getAddress())),
      await Promise.all(fixture.standby.map((signer) => signer.getAddress())),
      ethers.id("group-key:v2"),
      ethers.id("membership-root:v2"),
      ethers.id("standby-root:v2"),
      2,
    );
    await expect(
      fixture.verifier.verifyPlacementCertificate(placement, placementSignatures),
    ).to.be.revertedWithCustomError(
      fixture.verifier,
      "StaleMembershipCertificate",
    );
  });

    it("AssetAdmissionRegistryV1 enforces randomized quote bands and stale-oracle fail-closed behavior", async function () {
      const fixture = await deployGatewayFixture();
      const asset = await fixture.token.getAddress();
      await fc.assert(
        fc.asyncProperty(
          fc.integer({ min: 1, max: 100 }),
          async (wholeUnits) => {
            const amount = ethers.parseEther(String(wholeUnits));
            const [, notionalUsdc6] =
              await fixture.admission.validateIngress(asset, amount);
            expect(notionalUsdc6).to.equal(BigInt(wholeUnits) * 1_000_000n);
          },
        ),
        { numRuns: 12 },
      );

      await expect(
        fixture.admission.validateIngress(asset, ethers.parseEther("101")),
      ).to.be.revertedWithCustomError(
        fixture.admission,
        "OutsideAdmissionBand",
      );
      const block = await ethers.provider.getBlock("latest");
      if (!block) throw new Error("missing block");
      await fixture.oracle.setQuote(1_000_000, block.timestamp - 3601);
      await expect(
        fixture.admission.validateIngress(asset, ethers.parseEther("1")),
      ).to.be.revertedWithCustomError(fixture.admission, "OracleStale");

      const snapshot = await fixture.admission.policyByAdapterEpoch(asset, 1);
      expect(snapshot.policyVersion).to.equal(1);
      await fixture.admission.setAssetStatus(asset, 4);
      await expect(
        fixture.admission.validateIngress(asset, ethers.parseEther("1")),
      ).to.be.revertedWithCustomError(fixture.admission, "AssetNotActive");
      const exitPolicy = await fixture.admission.validateExitAuthority(
        asset,
        1,
        await fixture.treasury.getAddress(),
      );
      expect(exitPolicy[8]).to.equal(1);
    });

    it("locks implementations and permits upgrades only through the proxy owner", async function () {
      const [owner, outsider] = await ethers.getSigners();
      const queue = await deployProxy("L1QueueAccumulatorV1", [
        await owner.getAddress(),
      ]);
      const replacement = await ethers.deployContract("L1QueueAccumulatorV1");
      await replacement.waitForDeployment();

      await expect(
        replacement.initialize(await owner.getAddress()),
      ).to.be.revertedWithCustomError(replacement, "InvalidInitialization");
      await expect(
        queue
          .connect(outsider)
          .upgradeToAndCall(await replacement.getAddress(), "0x"),
      ).to.be.revertedWithCustomError(queue, "OwnableUnauthorizedAccount");
      await queue.upgradeToAndCall(await replacement.getAddress(), "0x");
      expect(await queue.owner()).to.equal(await owner.getAddress());
    });
});

function hashPair(left: string, right: string) {
  return ethers.keccak256(ethers.concat([left, right]));
}

function emptyAccumulatorRoot() {
  let root = ethers.ZeroHash;
  for (let level = 0; level < 32; level += 1) root = hashPair(root, root);
  return root;
}

function insertAccumulator(
  leafIndex: bigint,
  leaf: string,
  frontier: string[],
) {
  let current = leaf;
  let zero = ethers.ZeroHash;
  let index = leafIndex;
  for (let level = 0; level < 32; level += 1) {
    if ((index & 1n) === 0n) {
      frontier[level] = current;
      current = hashPair(current, zero);
    } else {
      current = hashPair(frontier[level], current);
    }
    zero = hashPair(zero, zero);
    index >>= 1n;
  }
  return current;
}
