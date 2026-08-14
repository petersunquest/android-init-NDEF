import { network } from "hardhat";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

export const { ethers } = await network.connect();

export async function deployProxy(name: string, initializeArgs: unknown[]) {
  const implementation = await ethers.deployContract(name);
  await implementation.waitForDeployment();
  const initialization = implementation.interface.encodeFunctionData(
    "initialize",
    initializeArgs,
  );
  const proxy = await ethers.deployContract("DLEERC1967Proxy", [
    await implementation.getAddress(),
    initialization,
  ]);
  await proxy.waitForDeployment();
  return ethers.getContractAt(name, await proxy.getAddress());
}

const archiveCertificateTypes = {
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

const placementCertificateTypes = {
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

export async function signSorted(
  signers: HardhatEthersSigner[],
  domain: Record<string, unknown>,
  types: Record<string, Array<{ name: string; type: string }>>,
  value: Record<string, unknown>,
) {
  const signed = await Promise.all(
    signers.map(async (signer) => ({
      address: (await signer.getAddress()).toLowerCase(),
      signature: await signer.signTypedData(domain, types, value),
    })),
  );
  signed.sort((a, b) => a.address.localeCompare(b.address));
  return signed.map((row) => row.signature);
}

export async function deployArchiveFixture() {
  const signers = await ethers.getSigners();
  const [owner, user, relayer, ...members] = signers;
  const active = members.slice(0, 5);
  const standby = members.slice(5, 7);
  const allArchiveMembers = [...active, ...standby];
  const operatorIds = await Promise.all(
    allArchiveMembers.map(async (signer) =>
      ethers.keccak256(ethers.solidityPacked(["address"], [await signer.getAddress()])),
    ),
  );

  const operatorRegistry = await deployProxy("OperatorDomainRegistryV1", [
    await owner.getAddress(),
  ]);
  const latest = await ethers.provider.getBlock("latest");
  if (!latest) throw new Error("missing latest block");
  for (let i = 0; i < operatorIds.length; i += 1) {
    const operatorId = operatorIds[i];
    await operatorRegistry.setOperatorRecord(operatorId, {
      controlCommitment: ethers.id(`control:${i}`),
      organizationCommitment: ethers.id(`org:${i}`),
      beneficiaryCommitment: ethers.id(`beneficiary:${i}`),
      validFrom: latest.timestamp,
      validUntil: latest.timestamp + 30 * 24 * 60 * 60,
      evidenceEpoch: 1,
      status: 2,
      mergedInto: ethers.ZeroHash,
    });
    await operatorRegistry.setInfrastructureClaim(operatorId, {
      exactTenantId: ethers.id(`tenant:${i}`),
      providerId: ethers.id(`provider:${i}`),
      regionId: ethers.id(`region:${i}`),
      facilityId: ethers.id(`facility:${i}`),
      networkPrefixId: ethers.id(`network:${i}`),
      billingEntityId: ethers.id(`billing:${i}`),
      validUntil: latest.timestamp + 30 * 24 * 60 * 60,
      disputed: false,
    });
    await operatorRegistry.setRoleUsage(operatorId, true, false);
  }

  const groupRegistry = await deployProxy("ArchiveGroupRegistryV1", [
    await owner.getAddress(),
    await operatorRegistry.getAddress(),
  ]);
  const membershipRoot = ethers.id("membership-root:v1");
  const standbyRoot = ethers.id("standby-root:v1");
  const groupKeyHash = ethers.id("group-key:v1");
  await groupRegistry.createGroup(
    operatorIds,
    await Promise.all(active.map((signer) => signer.getAddress())),
    await Promise.all(standby.map((signer) => signer.getAddress())),
    groupKeyHash,
    membershipRoot,
    standbyRoot,
    1,
  );

  const verifier = await deployProxy("ArchiveCertificateVerifierV1", [
    await owner.getAddress(),
    await groupRegistry.getAddress(),
  ]);
  const chainRegistry = await deployProxy("DLEChainRegistry1155V1", [
    await owner.getAddress(),
    "https://beamio.app/api/dle/{id}.json",
    await groupRegistry.getAddress(),
    await verifier.getAddress(),
    await owner.getAddress(),
  ]);

  const domain = {
    name: "CoNET-DLE-Archive",
    version: "1",
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: await verifier.getAddress(),
  };

  async function mintAndBindAssetChain(holder = user) {
    const tokenId = await chainRegistry
      .connect(holder)
      .mintChain.staticCall(await holder.getAddress(), 1);
    await chainRegistry.connect(holder).mintChain(await holder.getAddress(), 1);

    const block = await ethers.provider.getBlock("latest");
    if (!block) throw new Error("missing latest block");
    const requestId = ethers.id(`request:${tokenId}`);
    const assignmentId = ethers.id(`assignment:${tokenId}`);
    const deadline = block.timestamp + 3600;
    await chainRegistry.reserveArchiveGroup(
      tokenId,
      requestId,
      assignmentId,
      1,
      groupKeyHash,
      1,
      membershipRoot,
      standbyRoot,
      deadline,
    );
    const genesisAcHash = ethers.id(`genesis:${tokenId}`);
    const placement = {
      tokenId,
      requestId,
      assignmentId,
      attemptNonce: 1,
      groupId: 1,
      groupKeyHash,
      genesisAcHash,
      membershipEpoch: 1,
      membershipRoot,
      deadline,
    };
    const signatures = await signSorted(
      active.slice(0, 4),
      domain,
      placementCertificateTypes,
      placement,
    );
    await chainRegistry.finalizeArchiveGroup(tokenId, genesisAcHash, signatures);
    return tokenId;
  }

  async function nextArchiveCertificate(
    chainNftId: bigint,
    options: { l1ContextBlockNumber?: bigint; l1ContextBlockHash?: string } = {},
  ) {
    const latestAc = await (
      await ethers.getContractAt("AssetBurnMintGateway", gatewayAddressHolder.value)
    ).latestKnownAc(chainNftId);
    const certificate = {
      archiveGroupId: 1,
      membershipEpoch: 1,
      keyEpoch: 1,
      chainNftId,
      tipHeight: latestAc.height + 1n,
      attemptNonce: 1,
      parentArchiveCertificateHash: latestAc.certificateHash,
      stateRoot: ethers.id(`state:${chainNftId}:${latestAc.height + 1n}`),
      daRoot: ethers.id(`da:${chainNftId}:${latestAc.height + 1n}`),
      membershipRoot,
      l1ContextBlockNumber: options.l1ContextBlockNumber ?? 0n,
      l1ContextBlockHash: options.l1ContextBlockHash ?? ethers.ZeroHash,
    };
    const signatures = await signSorted(
      active.slice(0, 4),
      domain,
      archiveCertificateTypes,
      certificate,
    );
    return { certificate, signatures };
  }

  const gatewayAddressHolder = { value: ethers.ZeroAddress };
  return {
    owner,
    user,
    relayer,
    active,
    standby,
    operatorIds,
    operatorRegistry,
    groupRegistry,
    verifier,
    chainRegistry,
    domain,
    membershipRoot,
    standbyRoot,
    groupKeyHash,
    mintAndBindAssetChain,
    nextArchiveCertificate,
    setGatewayAddress: (value: string) => {
      gatewayAddressHolder.value = value;
    },
  };
}

export async function deployGatewayFixture() {
  const archive = await deployArchiveFixture();
  const tokenId = await archive.mintAndBindAssetChain();
  const token = await deployProxy("MockCanonicalAsset", [
    await archive.owner.getAddress(),
    "DLE Test USD",
    "dUSD",
  ]);
  const oracle = await deployProxy("MockOracleAdapterV1", [
    await archive.owner.getAddress(),
    ethers.parseEther("1"),
    1_000_000,
  ]);
  const treasury = await deployProxy("MockTreasuryDleAuthorityV1", [
    await archive.owner.getAddress(),
  ]);
  await token.setAuthority(await treasury.getAddress());
  await treasury.configureAsset(await token.getAddress(), ethers.parseEther("1000000"));

  const admission = await deployProxy("AssetAdmissionRegistryV1", [
    await archive.owner.getAddress(),
  ]);
  await admission.setAssetPolicy(
    await token.getAddress(),
    await treasury.getAddress(),
    await oracle.getAddress(),
    ethers.ZeroHash,
    ethers.ZeroHash,
    ethers.id("mock-mint-authority-proof"),
    1,
    3600,
    1_000_000,
    100_000_000,
    ethers.parseEther("1000000"),
    1,
  );
  const dispute = await deployProxy("DLEArchiveDisputeManagerV1", [
    await archive.owner.getAddress(),
    60,
    0,
  ]);
  const gateway = await deployProxy("AssetBurnMintGateway", [
    await archive.owner.getAddress(),
    await admission.getAddress(),
    await archive.verifier.getAddress(),
    await archive.chainRegistry.getAddress(),
    await dispute.getAddress(),
    60,
    120,
  ]);
  archive.setGatewayAddress(await gateway.getAddress());
  await treasury.setGateway(await gateway.getAddress());
  await token.mint(await archive.user.getAddress(), ethers.parseEther("10000"));

  return {
    ...archive,
    tokenId,
    token,
    oracle,
    treasury,
    admission,
    dispute,
    gateway,
  };
}
