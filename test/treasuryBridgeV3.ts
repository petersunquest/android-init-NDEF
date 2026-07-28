import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

const ATTESTATION_TYPES = {
  BridgeAttestation: [
    { name: "operationId", type: "bytes32" },
    { name: "sourceChainId", type: "uint256" },
    { name: "destinationChainId", type: "uint256" },
    { name: "sourceTreasury", type: "address" },
    { name: "sourceAsset", type: "address" },
    { name: "destinationAsset", type: "address" },
    { name: "beneficiariesHash", type: "bytes32" },
    { name: "mode", type: "uint8" },
    { name: "grossAmount", type: "uint256" },
    { name: "feeAmount", type: "uint256" },
    { name: "sourceTxHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

function beneficiariesHash(beneficiaries: string[], amounts: bigint[]) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["address[]", "uint256[]"], [beneficiaries, amounts]),
  );
}

describe("TreasuryBridgeV3", function () {
  async function deployStack() {
    const [owner, miner, miner2, miner3, user, beneficiary, beneficiary2] =
      await ethers.getSigners();
    const bridgeImpl = await (await ethers.getContractFactory("TreasuryBridgeV3")).deploy();
    await bridgeImpl.waitForDeployment();
    const bridgeInit = bridgeImpl.interface.encodeFunctionData("initialize", [
      owner.address,
      [miner.address],
    ]);
    const proxy = await (
      await ethers.getContractFactory("TreasuryV3ERC1967Proxy")
    ).deploy(await bridgeImpl.getAddress(), bridgeInit);
    await proxy.waitForDeployment();
    const bridge = await ethers.getContractAt("TreasuryBridgeV3", await proxy.getAddress());

    const tokenImpl = await (await ethers.getContractFactory("TreasuryCanonicalERC20V3")).deploy();
    await tokenImpl.waitForDeployment();
    const tokenInit = tokenImpl.interface.encodeFunctionData("initialize", [
      "Canonical Token",
      "CAN",
      6,
      owner.address,
      await proxy.getAddress(),
      "https://mainnet.conet.network/test/erc20/metadata.json",
    ]);
    const tokenProxy = await (
      await ethers.getContractFactory("TreasuryV3ERC1967Proxy")
    ).deploy(await tokenImpl.getAddress(), tokenInit);
    await tokenProxy.waitForDeployment();
    const token = await ethers.getContractAt(
      "TreasuryCanonicalERC20V3",
      await tokenProxy.getAddress(),
    );
    return { owner, miner, miner2, miner3, user, beneficiary, beneficiary2, bridge, token };
  }

  async function approveBurnMint(
    bridge: any,
    miner: any,
    sourceAsset: string,
    destinationAsset: string,
    mode = 0,
  ) {
    const policy = {
      sourceChainId: (await ethers.provider.getNetwork()).chainId,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset,
      mode,
      decimals: 6,
      enabled: true,
      version: 1,
    };
    await bridge.connect(miner).proposeAssetPolicy(policy);
    return policy;
  }

  it("requires miner governance before executing a route", async function () {
    const { owner, miner, bridge, token } = await deployStack();
    const policy = await approveBurnMint(
      bridge,
      miner,
      await token.getAddress(),
      await token.getAddress(),
    );
    const id = await bridge.policyId(policy);
    expect((await bridge.assetPolicy(id)).enabled).to.equal(true);
    await expect(
      bridge.setDestinationFeeBps(224422, 1001),
    ).to.be.revertedWithCustomError(bridge, "InvalidFee");
    expect(await bridge.requiredVotes()).to.equal(1n);
    expect(await bridge.owner()).to.equal(owner.address);
  });

  it("verifies the unified attestation and rejects replay", async function () {
    const { owner, miner, user, beneficiary, bridge, token } = await deployStack();
    const sourceAsset = await token.getAddress();
    const destinationAsset = await token.getAddress();
    await approveBurnMint(bridge, miner, sourceAsset, destinationAsset);
    await bridge.setDestinationFeeBps(8453, 100);

    const gross = 1_000_000n;
    const fee = 10_000n;
    const beneficiaries = [beneficiary.address];
    const amounts = [gross];
    const sourceTxHash = ethers.keccak256(ethers.toUtf8Bytes("source"));
    const nonce = 7n;
    const operationId = ethers.keccak256(ethers.toUtf8Bytes("operation"));
    const network = await ethers.provider.getNetwork();
    const domain = {
      name: "TreasuryBridgeV3",
      version: "1",
      chainId: network.chainId,
      verifyingContract: await bridge.getAddress(),
    };
    const value = {
      operationId,
      sourceChainId: network.chainId,
      destinationChainId: 8453n,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset,
      beneficiariesHash: beneficiariesHash(beneficiaries, amounts),
      mode: 0,
      grossAmount: gross,
      feeAmount: fee,
      sourceTxHash,
      nonce,
    };
    const signature = await miner.signTypedData(domain, ATTESTATION_TYPES, value);
    expect(
      await bridge.bridgeAttestationDigest(
        operationId,
        network.chainId,
        8453,
        await bridge.getAddress(),
        sourceAsset,
        destinationAsset,
        beneficiaries,
        amounts,
        0,
        gross,
        fee,
        sourceTxHash,
        nonce,
      ),
    ).to.equal(ethers.TypedDataEncoder.hash(domain, ATTESTATION_TYPES, value));
    await bridge.executeMint(
      operationId,
      network.chainId,
      8453,
      await bridge.getAddress(),
      sourceAsset,
      destinationAsset,
      beneficiaries,
      amounts,
      0,
      gross,
      fee,
      sourceTxHash,
      nonce,
      [signature],
    );
    expect(await token.balanceOf(beneficiary.address)).to.equal(gross);
    await expect(
      bridge.executeMint(
        operationId,
        network.chainId,
        8453,
        await bridge.getAddress(),
        sourceAsset,
        destinationAsset,
        beneficiaries,
        amounts,
        0,
        gross,
        fee,
        sourceTxHash,
        nonce,
        [signature],
      ),
    ).to.be.revertedWithCustomError(bridge, "OperationAlreadyUsed");
    expect(await token.balanceOf(user.address)).to.equal(0);
    expect(await bridge.owner()).to.equal(owner.address);
  });

  it("splits destination mint across multiple beneficiaries", async function () {
    const { miner, beneficiary, beneficiary2, bridge, token } = await deployStack();
    const sourceAsset = await token.getAddress();
    await approveBurnMint(bridge, miner, sourceAsset, sourceAsset);
    const network = await ethers.provider.getNetwork();
    const gross = 1_000_000n;
    const shareA = 600_000n;
    const shareB = 400_000n;
    const beneficiaries = [beneficiary.address, beneficiary2.address];
    const amounts = [shareA, shareB];
    const operationId = ethers.keccak256(ethers.toUtf8Bytes("multi-beneficiaries"));
    const sourceTxHash = ethers.keccak256(ethers.toUtf8Bytes("multi-source"));
    const domain = {
      name: "TreasuryBridgeV3",
      version: "1",
      chainId: network.chainId,
      verifyingContract: await bridge.getAddress(),
    };
    const value = {
      operationId,
      sourceChainId: network.chainId,
      destinationChainId: 8453n,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset: sourceAsset,
      beneficiariesHash: beneficiariesHash(beneficiaries, amounts),
      mode: 0,
      grossAmount: gross,
      feeAmount: 0n,
      sourceTxHash,
      nonce: 11n,
    };
    const signature = await miner.signTypedData(domain, ATTESTATION_TYPES, value);
    await bridge.executeMint(
      operationId,
      network.chainId,
      8453,
      await bridge.getAddress(),
      sourceAsset,
      sourceAsset,
      beneficiaries,
      amounts,
      0,
      gross,
      0,
      sourceTxHash,
      11,
      [signature],
    );
    expect(await token.balanceOf(beneficiary.address)).to.equal(shareA);
    expect(await token.balanceOf(beneficiary2.address)).to.equal(shareB);
  });

  it("rejects beneficiary arrays that do not sum to grossAmount", async function () {
    const { miner, beneficiary, beneficiary2, bridge, token } = await deployStack();
    const sourceAsset = await token.getAddress();
    await approveBurnMint(bridge, miner, sourceAsset, sourceAsset);
    const network = await ethers.provider.getNetwork();
    const operationId = ethers.keccak256(ethers.toUtf8Bytes("bad-sum"));
    await expect(
      bridge.connect(miner).voteBridgeOperation(
        operationId,
        8453n,
        network.chainId,
        await bridge.getAddress(),
        sourceAsset,
        sourceAsset,
        [beneficiary.address, beneficiary2.address],
        [600_000n, 300_000n],
        1,
        1_000_000n,
        10_000n,
        ethers.keccak256(ethers.toUtf8Bytes("bad-sum-tx")),
        12n,
      ),
    ).to.be.revertedWithCustomError(bridge, "InvalidBeneficiaries");
  });

  it("locks the gross amount and leaves the configured fee in the treasury", async function () {
    const { miner, user, beneficiary, bridge, token } = await deployStack();
    const sourceAsset = await token.getAddress();
    await approveBurnMint(bridge, miner, sourceAsset, sourceAsset, 1);
    await bridge.setDestinationFeeBps(8453, 100);
    const network = await ethers.provider.getNetwork();
    const seedOperation = ethers.keccak256(ethers.toUtf8Bytes("seed"));
    const seedTx = ethers.keccak256(ethers.toUtf8Bytes("seed-tx"));
    const beneficiaries = [user.address];
    const amounts = [1_000_000n];
    const seedValue = {
      operationId: seedOperation,
      sourceChainId: network.chainId,
      destinationChainId: 8453n,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset: sourceAsset,
      beneficiariesHash: beneficiariesHash(beneficiaries, amounts),
      mode: 1,
      grossAmount: 1_000_000n,
      feeAmount: 10_000n,
      sourceTxHash: seedTx,
      nonce: 1n,
    };
    const seedSignature = await miner.signTypedData(
      {
        name: "TreasuryBridgeV3",
        version: "1",
        chainId: network.chainId,
        verifyingContract: await bridge.getAddress(),
      },
      ATTESTATION_TYPES,
      seedValue,
    );
    await bridge.executeMint(
      seedOperation,
      network.chainId,
      8453,
      await bridge.getAddress(),
      sourceAsset,
      sourceAsset,
      beneficiaries,
      amounts,
      1,
      1_000_000n,
      10_000n,
      seedTx,
      1,
      [seedSignature],
    );
    await token.connect(user).approve(await bridge.getAddress(), 999_900n);
    await bridge.connect(user).initiateLockMint(
      8453,
      sourceAsset,
      sourceAsset,
      [beneficiary.address],
      [990_000n],
      ethers.keccak256(ethers.toUtf8Bytes("lock")),
      1,
    );
    expect(await token.balanceOf(await bridge.getAddress())).to.equal(999_900n);
    expect(await token.balanceOf(user.address)).to.equal(100n);
  });

  it("lets a user burn the requested amount and charges the fee separately", async function () {
    const { miner, user, beneficiary, bridge, token } = await deployStack();
    const sourceAsset = await token.getAddress();
    await bridge.setBridgeAssetAuthorization(sourceAsset, true);
    const policy = {
      sourceChainId: (await ethers.provider.getNetwork()).chainId,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset: sourceAsset,
      mode: 0,
      decimals: 6,
      enabled: true,
      version: 1,
    };
    await bridge.connect(miner).proposeAssetPolicy(policy);
    await bridge.setDestinationFeeBps(8453, 100);

    const requested = 1_000_000n;
    const fee = 10_000n;
    const seedOperation = ethers.keccak256(ethers.toUtf8Bytes("burn-mint-seed"));
    const seedTx = ethers.keccak256(ethers.toUtf8Bytes("burn-mint-seed-tx"));
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const beneficiaries = [user.address];
    const amounts = [requested + fee];
    const seedValue = {
      operationId: seedOperation,
      sourceChainId: chainId,
      destinationChainId: 8453n,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset: sourceAsset,
      beneficiariesHash: beneficiariesHash(beneficiaries, amounts),
      mode: 0,
      grossAmount: requested + fee,
      feeAmount: 0n,
      sourceTxHash: seedTx,
      nonce: 3n,
    };
    const seedSignature = await miner.signTypedData(
      {
        name: "TreasuryBridgeV3",
        version: "1",
        chainId,
        verifyingContract: await bridge.getAddress(),
      },
      ATTESTATION_TYPES,
      seedValue,
    );
    await bridge.executeMint(
      seedOperation,
      chainId,
      8453,
      await bridge.getAddress(),
      sourceAsset,
      sourceAsset,
      beneficiaries,
      amounts,
      0,
      requested + fee,
      0,
      seedTx,
      3,
      [seedSignature],
    );
    await token.connect(user).approve(await bridge.getAddress(), fee);
    await bridge.connect(user).initiateBurnMintForUser(
      sourceAsset,
      8453,
      sourceAsset,
      [beneficiary.address],
      [requested],
      ethers.keccak256(ethers.toUtf8Bytes("burn-mint")),
      2,
    );

    expect(await token.balanceOf(user.address)).to.equal(0n);
    expect(await token.balanceOf(await bridge.getAddress())).to.equal(fee);
  });

  it("allows miners to vote on-chain and auto-executes at quorum", async function () {
    const { owner, miner, miner2, miner3, beneficiary, bridge, token } = await deployStack();
    const network = await ethers.provider.getNetwork();
    const sourceChainId = 8453n;
    const destinationChainId = network.chainId;
    const sourceAsset = await token.getAddress();
    const destinationAsset = sourceAsset;
    const policy = {
      sourceChainId,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset,
      mode: 1,
      decimals: 6,
      enabled: true,
      version: 1,
    };
    await bridge.connect(miner).proposeAssetPolicy(policy);
    await bridge.connect(owner).addMiner(miner2.address);
    await bridge.connect(owner).addMiner(miner3.address);
    await bridge.setDestinationFeeBps(destinationChainId, 100);

    const operationId = ethers.keccak256(ethers.toUtf8Bytes("direct-vote-operation"));
    const sourceTxHash = ethers.keccak256(ethers.toUtf8Bytes("direct-vote-source"));
    const args = [
      operationId,
      sourceChainId,
      destinationChainId,
      await bridge.getAddress(),
      sourceAsset,
      destinationAsset,
      [beneficiary.address],
      [1_000_000n],
      1,
      1_000_000n,
      10_000n,
      sourceTxHash,
      9n,
    ] as const;

    await bridge.connect(miner).voteBridgeOperation(...args);
    expect(await bridge.bridgeOperationVoteCount(operationId)).to.equal(1n);
    expect(await token.balanceOf(beneficiary.address)).to.equal(0n);

    await bridge.connect(miner2).voteBridgeOperation(...args);
    expect(await bridge.operationExecuted(operationId)).to.equal(true);
    expect(await token.balanceOf(beneficiary.address)).to.equal(1_000_000n);
    await expect(bridge.connect(miner3).voteBridgeOperation(...args))
      .to.be.revertedWithCustomError(bridge, "OperationAlreadyUsed");
  });

  it("allows miners to vote with multiple beneficiaries and split release/mint", async function () {
    const { owner, miner, miner2, beneficiary, beneficiary2, bridge, token } = await deployStack();
    const network = await ethers.provider.getNetwork();
    const sourceChainId = 8453n;
    const destinationChainId = network.chainId;
    const sourceAsset = await token.getAddress();
    const policy = {
      sourceChainId,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset: sourceAsset,
      mode: 1,
      decimals: 6,
      enabled: true,
      version: 1,
    };
    await bridge.connect(miner).proposeAssetPolicy(policy);
    await bridge.connect(owner).addMiner(miner2.address);

    const operationId = ethers.keccak256(ethers.toUtf8Bytes("multi-vote"));
    const sourceTxHash = ethers.keccak256(ethers.toUtf8Bytes("multi-vote-source"));
    const beneficiaries = [beneficiary.address, beneficiary2.address];
    const amounts = [700_000n, 300_000n];
    const args = [
      operationId,
      sourceChainId,
      destinationChainId,
      await bridge.getAddress(),
      sourceAsset,
      sourceAsset,
      beneficiaries,
      amounts,
      1,
      1_000_000n,
      10_000n,
      sourceTxHash,
      13n,
    ] as const;

    await bridge.connect(miner).voteBridgeOperation(...args);
    await bridge.connect(miner2).voteBridgeOperation(...args);
    expect(await token.balanceOf(beneficiary.address)).to.equal(700_000n);
    expect(await token.balanceOf(beneficiary2.address)).to.equal(300_000n);
  });
});
