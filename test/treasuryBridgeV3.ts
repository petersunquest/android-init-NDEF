import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("TreasuryBridgeV3", function () {
  async function deployStack() {
    const [owner, miner, miner2, miner3, user, beneficiary] = await ethers.getSigners();
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
    return { owner, miner, miner2, miner3, user, beneficiary, bridge, token };
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
    const types = {
      BridgeAttestation: [
        { name: "operationId", type: "bytes32" },
        { name: "sourceChainId", type: "uint256" },
        { name: "destinationChainId", type: "uint256" },
        { name: "sourceTreasury", type: "address" },
        { name: "sourceAsset", type: "address" },
        { name: "destinationAsset", type: "address" },
        { name: "beneficiary", type: "address" },
        { name: "mode", type: "uint8" },
        { name: "grossAmount", type: "uint256" },
        { name: "feeAmount", type: "uint256" },
        { name: "sourceTxHash", type: "bytes32" },
        { name: "nonce", type: "uint256" },
      ],
    };
    const value = {
      operationId,
      sourceChainId: network.chainId,
      destinationChainId: 8453n,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset,
      beneficiary: beneficiary.address,
      mode: 0,
      grossAmount: gross,
      feeAmount: fee,
      sourceTxHash,
      nonce,
    };
    const signature = await miner.signTypedData(domain, types, value);
    expect(
      await bridge.bridgeAttestationDigest(
        operationId,
        network.chainId,
        8453,
        await bridge.getAddress(),
        sourceAsset,
        destinationAsset,
        beneficiary.address,
        0,
        gross,
        fee,
        sourceTxHash,
        nonce,
      ),
    ).to.equal(ethers.TypedDataEncoder.hash(domain, types, value));
    await bridge.executeMint(
      operationId,
      network.chainId,
      8453,
      await bridge.getAddress(),
      sourceAsset,
      destinationAsset,
      beneficiary.address,
      0,
      gross,
      fee,
      sourceTxHash,
      nonce,
      [signature],
    );
    expect(await token.balanceOf(beneficiary.address)).to.equal(gross - fee);
    await expect(
      bridge.executeMint(
        operationId,
        network.chainId,
        8453,
        await bridge.getAddress(),
        sourceAsset,
        destinationAsset,
        beneficiary.address,
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

  it("locks the gross amount and leaves the configured fee in the treasury", async function () {
    const { miner, user, beneficiary, bridge, token } = await deployStack();
    const sourceAsset = await token.getAddress();
    await approveBurnMint(bridge, miner, sourceAsset, sourceAsset, 1);
    await bridge.setDestinationFeeBps(8453, 100);
    const network = await ethers.provider.getNetwork();
    const seedOperation = ethers.keccak256(ethers.toUtf8Bytes("seed"));
    const seedTx = ethers.keccak256(ethers.toUtf8Bytes("seed-tx"));
    const seedValue = {
      operationId: seedOperation,
      sourceChainId: network.chainId,
      destinationChainId: 8453n,
      sourceTreasury: await bridge.getAddress(),
      sourceAsset,
      destinationAsset: sourceAsset,
      beneficiary: user.address,
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
      {
        BridgeAttestation: [
          { name: "operationId", type: "bytes32" },
          { name: "sourceChainId", type: "uint256" },
          { name: "destinationChainId", type: "uint256" },
          { name: "sourceTreasury", type: "address" },
          { name: "sourceAsset", type: "address" },
          { name: "destinationAsset", type: "address" },
          { name: "beneficiary", type: "address" },
          { name: "mode", type: "uint8" },
          { name: "grossAmount", type: "uint256" },
          { name: "feeAmount", type: "uint256" },
          { name: "sourceTxHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
        ],
      },
      seedValue,
    );
    await bridge.executeMint(
      seedOperation,
      network.chainId,
      8453,
      await bridge.getAddress(),
      sourceAsset,
      sourceAsset,
      user.address,
      1,
      1_000_000n,
      10_000n,
      seedTx,
      1,
      [seedSignature],
    );
    await token.connect(user).approve(await bridge.getAddress(), 990_000n);
    await bridge.connect(user).initiateLockMint(
      8453,
      sourceAsset,
      sourceAsset,
      beneficiary.address,
      990_000n,
      ethers.keccak256(ethers.toUtf8Bytes("lock")),
      1,
    );
    expect(await token.balanceOf(await bridge.getAddress())).to.equal(990_000n);
    expect(await token.balanceOf(user.address)).to.equal(0);
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
      mode: 0,
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
      beneficiary.address,
      0,
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
    expect(await token.balanceOf(beneficiary.address)).to.equal(990_000n);
    await expect(bridge.connect(miner3).voteBridgeOperation(...args))
      .to.be.revertedWithCustomError(bridge, "OperationAlreadyUsed");
  });
});
