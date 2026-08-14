// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {DLEUpgradeableBase} from "./DLEUpgradeableBase.sol";
import {ArchiveGroupRegistryV1} from "./ArchiveGroupRegistryV1.sol";

/// @notice EIP-712 archive certificate verifier for the MVP's explicit
/// secp256k1 4-of-5 finality path.
contract ArchiveCertificateVerifierV1 is DLEUpgradeableBase, EIP712Upgradeable {
    uint8 private constant _ACTIVE_COUNT = 5;
    uint8 private constant _QUORUM = 4;

    struct ArchiveCertificateV1 {
        uint64 archiveGroupId;
        uint64 membershipEpoch;
        uint64 keyEpoch;
        uint256 chainNftId;
        uint64 tipHeight;
        uint64 attemptNonce;
        bytes32 parentArchiveCertificateHash;
        bytes32 stateRoot;
        bytes32 daRoot;
        bytes32 membershipRoot;
        uint64 l1ContextBlockNumber;
        bytes32 l1ContextBlockHash;
    }

    struct PlacementCertificateV1 {
        uint256 tokenId;
        bytes32 requestId;
        bytes32 assignmentId;
        uint64 attemptNonce;
        uint64 groupId;
        bytes32 groupKeyHash;
        bytes32 genesisAcHash;
        uint64 membershipEpoch;
        bytes32 membershipRoot;
        uint64 deadline;
    }

    bytes32 public constant ARCHIVE_CERTIFICATE_TYPEHASH = keccak256(
        "ArchiveCertificateV1(uint64 archiveGroupId,uint64 membershipEpoch,uint64 keyEpoch,uint256 chainNftId,uint64 tipHeight,uint64 attemptNonce,bytes32 parentArchiveCertificateHash,bytes32 stateRoot,bytes32 daRoot,bytes32 membershipRoot,uint64 l1ContextBlockNumber,bytes32 l1ContextBlockHash)"
    );
    bytes32 public constant PLACEMENT_CERTIFICATE_TYPEHASH = keccak256(
        "PlacementCertificateV1(uint256 tokenId,bytes32 requestId,bytes32 assignmentId,uint64 attemptNonce,uint64 groupId,bytes32 groupKeyHash,bytes32 genesisAcHash,uint64 membershipEpoch,bytes32 membershipRoot,uint64 deadline)"
    );

    error UnknownMembershipCheckpoint();
    error MembershipRootMismatch();
    error KeyEpochMismatch();
    error InvalidCertificateField();
    error InvalidL1Context();
    error InsufficientQuorum();
    error TooManySignatures();
    error SignersNotStrictlySorted();
    error SignerNotActiveMember();
    error StaleMembershipCertificate();

    ArchiveGroupRegistryV1 public groupRegistry;

    event GroupRegistrySet(address indexed registry);

    function initialize(address initialOwner, address groupRegistry_) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        __EIP712_init("CoNET-DLE-Archive", "1");
        if (groupRegistry_ == address(0)) revert ZeroAddress();
        groupRegistry = ArchiveGroupRegistryV1(groupRegistry_);
    }

    function setGroupRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        groupRegistry = ArchiveGroupRegistryV1(registry);
        emit GroupRegistrySet(registry);
    }

    function hashArchiveCertificate(
        ArchiveCertificateV1 calldata certificate
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ARCHIVE_CERTIFICATE_TYPEHASH,
                    certificate.archiveGroupId,
                    certificate.membershipEpoch,
                    certificate.keyEpoch,
                    certificate.chainNftId,
                    certificate.tipHeight,
                    certificate.attemptNonce,
                    certificate.parentArchiveCertificateHash,
                    certificate.stateRoot,
                    certificate.daRoot,
                    certificate.membershipRoot,
                    certificate.l1ContextBlockNumber,
                    certificate.l1ContextBlockHash
                )
            )
        );
    }

    function hashPlacementCertificate(
        PlacementCertificateV1 calldata certificate
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PLACEMENT_CERTIFICATE_TYPEHASH,
                    certificate.tokenId,
                    certificate.requestId,
                    certificate.assignmentId,
                    certificate.attemptNonce,
                    certificate.groupId,
                    certificate.groupKeyHash,
                    certificate.genesisAcHash,
                    certificate.membershipEpoch,
                    certificate.membershipRoot,
                    certificate.deadline
                )
            )
        );
    }

    function verifyArchiveCertificate(
        ArchiveCertificateV1 calldata certificate,
        bytes[] calldata signatures
    ) external view returns (bytes32 certificateHash) {
        if (
            certificate.archiveGroupId == 0 ||
            certificate.chainNftId == 0 ||
            certificate.stateRoot == bytes32(0) ||
            certificate.daRoot == bytes32(0)
        ) revert InvalidCertificateField();
        if (certificate.l1ContextBlockNumber > block.number) revert InvalidL1Context();
        if (
            certificate.l1ContextBlockNumber != 0 &&
            block.number - certificate.l1ContextBlockNumber <= 256 &&
            blockhash(certificate.l1ContextBlockNumber) != certificate.l1ContextBlockHash
        ) revert InvalidL1Context();
        certificateHash = hashArchiveCertificate(certificate);
        _verifyQuorum(
            certificate.archiveGroupId,
            certificate.membershipEpoch,
            certificate.keyEpoch,
            certificate.membershipRoot,
            certificateHash,
            signatures
        );
    }

    function verifyPlacementCertificate(
        PlacementCertificateV1 calldata certificate,
        bytes[] calldata signatures
    ) external view returns (bytes32 certificateHash) {
        if (
            certificate.tokenId == 0 ||
            certificate.assignmentId == bytes32(0) ||
            certificate.genesisAcHash == bytes32(0) ||
            certificate.deadline < block.timestamp
        ) revert InvalidCertificateField();
        (
            uint64 currentEpoch,
            bytes32 currentGroupKeyHash,
            bytes32 currentMembershipRoot
        ) = groupRegistry.currentGroupCommitment(certificate.groupId);
        if (
            currentEpoch != certificate.membershipEpoch ||
            currentGroupKeyHash != certificate.groupKeyHash ||
            currentMembershipRoot != certificate.membershipRoot
        ) revert StaleMembershipCertificate();
        certificateHash = hashPlacementCertificate(certificate);
        (, , uint64 keyEpoch, , bool exists) =
            groupRegistry.checkpoints(certificate.groupId, certificate.membershipEpoch);
        if (!exists) revert UnknownMembershipCheckpoint();
        _verifyQuorum(
            certificate.groupId,
            certificate.membershipEpoch,
            keyEpoch,
            certificate.membershipRoot,
            certificateHash,
            signatures
        );
    }

    function _verifyQuorum(
        uint64 groupId,
        uint64 membershipEpoch,
        uint64 keyEpoch,
        bytes32 membershipRoot,
        bytes32 digest,
        bytes[] calldata signatures
    ) private view {
        (bytes32 storedRoot, , uint64 storedKeyEpoch, , bool exists) =
            groupRegistry.checkpoints(groupId, membershipEpoch);
        if (!exists) revert UnknownMembershipCheckpoint();
        if (storedRoot != membershipRoot) revert MembershipRootMismatch();
        if (storedKeyEpoch != keyEpoch) revert KeyEpochMismatch();
        if (signatures.length < _QUORUM) revert InsufficientQuorum();
        if (signatures.length > _ACTIVE_COUNT) revert TooManySignatures();

        address previous;
        for (uint256 i; i < signatures.length; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer <= previous) revert SignersNotStrictlySorted();
            if (!groupRegistry.isActiveMember(groupId, membershipEpoch, signer)) {
                revert SignerNotActiveMember();
            }
            previous = signer;
        }
    }

    uint256[46] private __gap;
}
