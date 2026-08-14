// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {DLEUpgradeableBase} from "./DLEUpgradeableBase.sol";
import {ArchiveCertificateVerifierV1} from "./ArchiveCertificateVerifierV1.sol";
import {ArchiveGroupRegistryV1} from "./ArchiveGroupRegistryV1.sol";

/// @notice Minimal one-of-one ERC-1155 registry for DLE chain identity,
/// ternary class, canonical owner and archive-group placement.
contract DLEChainRegistry1155V1 is DLEUpgradeableBase, ERC1155Upgradeable {
    enum ChainClass {
        NONE,
        ASSET,
        STORAGE,
        TRADE
    }

    enum AssignmentStatus {
        QUEUED,
        RESERVED,
        BOUND,
        EXPIRED
    }

    struct Assignment {
        bytes32 requestId;
        bytes32 assignmentId;
        bytes32 groupKeyHash;
        bytes32 membershipRoot;
        bytes32 standbyRoot;
        uint64 groupId;
        uint64 membershipEpoch;
        uint64 attemptNonce;
        uint64 deadline;
        AssignmentStatus status;
    }

    /// @notice Immutable audit record for an L1-authorized archive re-home.
    /// @dev The placement controller must obtain the source/destination
    /// certificate before calling this registry.  This contract deliberately
    /// records the committed roots rather than deriving a host from tokenId.
    struct MigrationCheckpoint {
        uint64 fromGroupId;
        uint64 toGroupId;
        uint64 fromMembershipEpoch;
        uint64 toMembershipEpoch;
        uint64 recordedAtBlock;
        bytes32 migrationId;
        bytes32 fromMembershipRoot;
        bytes32 toMembershipRoot;
    }

    error InvalidClass();
    error UnknownToken();
    error NotChainOwner();
    error InvalidAssignmentState();
    error AssignmentExpired();
    error AssignmentNotExpired();
    error AssignmentMismatch();
    error DuplicateAssignmentId();
    error GroupNotEligible();
    error UnauthorizedPlacementController();
    error InvalidChainAmount();
    error InvalidMembershipCheckpoint();
    error DuplicateMigrationId();

    uint256 public nextTokenId;
    address public placementController;
    ArchiveGroupRegistryV1 public groupRegistry;
    ArchiveCertificateVerifierV1 public certificateVerifier;

    mapping(uint256 => ChainClass) public chainClass;
    mapping(uint256 => address) public chainOwner;
    mapping(uint256 => uint64) public archiveGroupId;
    mapping(uint256 => Assignment) public assignments;
    mapping(bytes32 => bool) public assignmentIdUsed;
    mapping(uint256 => bytes32) public genesisAcHash;
    mapping(uint256 => bytes32) public genesisMembershipRoot;
    mapping(uint256 => uint64) public currentMembershipEpoch;
    mapping(uint256 => bytes32) public currentMembershipRoot;
    mapping(uint256 => uint64) public migrationCount;
    mapping(uint256 => mapping(uint64 => MigrationCheckpoint)) public migrationCheckpoints;
    mapping(bytes32 => bool) public migrationIdUsed;

    event ChainMinted(uint256 indexed tokenId, address indexed owner, ChainClass indexed chainClass);
    event ArchiveGroupReserved(
        uint256 indexed tokenId,
        bytes32 indexed assignmentId,
        uint64 indexed groupId,
        uint64 attemptNonce,
        uint64 deadline
    );
    event ArchiveGroupBound(uint256 indexed tokenId, uint64 indexed groupId, bytes32 indexed assignmentId);
    event ArchiveGroupReservationExpired(uint256 indexed tokenId, uint64 indexed groupId, uint64 attemptNonce);
    event MembershipCheckpointRecorded(
        uint256 indexed tokenId,
        uint64 indexed groupId,
        uint64 indexed membershipEpoch,
        bytes32 membershipRoot
    );
    event ArchiveGroupRehomed(
        uint256 indexed tokenId,
        uint64 indexed fromGroupId,
        uint64 indexed toGroupId,
        bytes32 migrationId
    );
    event PlacementControllerSet(address indexed controller);

    modifier onlyPlacementController() {
        if (msg.sender != placementController && msg.sender != owner()) {
            revert UnauthorizedPlacementController();
        }
        _;
    }

    function initialize(
        address initialOwner,
        string calldata baseUri,
        address groupRegistry_,
        address certificateVerifier_,
        address placementController_
    ) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        __ERC1155_init(baseUri);
        if (
            groupRegistry_ == address(0) ||
            certificateVerifier_ == address(0) ||
            placementController_ == address(0)
        ) revert ZeroAddress();
        groupRegistry = ArchiveGroupRegistryV1(groupRegistry_);
        certificateVerifier = ArchiveCertificateVerifierV1(certificateVerifier_);
        placementController = placementController_;
        nextTokenId = 1;
    }

    function mintChain(address to, ChainClass class_) external returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        if (class_ == ChainClass.NONE || uint8(class_) > uint8(ChainClass.TRADE)) revert InvalidClass();
        tokenId = nextTokenId++;
        chainClass[tokenId] = class_;
        chainOwner[tokenId] = to;
        _mint(to, tokenId, 1, "");
        emit ChainMinted(tokenId, to, class_);
    }

    function transferChain(address to, uint256 tokenId) external {
        if (chainOwner[tokenId] != msg.sender) revert NotChainOwner();
        if (to == address(0)) revert ZeroAddress();
        chainOwner[tokenId] = to;
        safeTransferFrom(msg.sender, to, tokenId, 1, "");
    }

    function reserveArchiveGroup(
        uint256 tokenId,
        bytes32 requestId,
        bytes32 assignmentId,
        uint64 groupId,
        bytes32 groupKeyHash,
        uint64 membershipEpoch,
        bytes32 membershipRoot,
        bytes32 standbyRoot,
        uint64 deadline
    ) external onlyPlacementController {
        if (chainOwner[tokenId] == address(0)) revert UnknownToken();
        if (archiveGroupId[tokenId] != 0) revert InvalidAssignmentState();
        Assignment storage current = assignments[tokenId];
        if (current.status == AssignmentStatus.RESERVED) revert InvalidAssignmentState();
        if (assignmentId == bytes32(0) || assignmentIdUsed[assignmentId]) revert DuplicateAssignmentId();
        if (deadline <= block.timestamp) revert AssignmentExpired();

        (
            bytes32 liveGroupKeyHash,
            bytes32 liveMembershipRoot,
            bytes32 liveStandbyRoot,
            uint64 liveMembershipEpoch,
            ,
            bool live,
            bool assignmentEligible
        ) = groupRegistry.groups(groupId);
        if (!live || !assignmentEligible) revert GroupNotEligible();
        if (
            liveGroupKeyHash != groupKeyHash ||
            liveMembershipEpoch != membershipEpoch ||
            liveMembershipRoot != membershipRoot ||
            liveStandbyRoot != standbyRoot
        ) revert AssignmentMismatch();

        uint64 attemptNonce = current.attemptNonce + 1;
        assignments[tokenId] = Assignment({
            requestId: requestId,
            assignmentId: assignmentId,
            groupKeyHash: groupKeyHash,
            membershipRoot: membershipRoot,
            standbyRoot: standbyRoot,
            groupId: groupId,
            membershipEpoch: membershipEpoch,
            attemptNonce: attemptNonce,
            deadline: deadline,
            status: AssignmentStatus.RESERVED
        });
        assignmentIdUsed[assignmentId] = true;
        emit ArchiveGroupReserved(tokenId, assignmentId, groupId, attemptNonce, deadline);
    }

    function finalizeArchiveGroup(
        uint256 tokenId,
        bytes32 genesisCertificateHash,
        bytes[] calldata signatures
    ) external {
        Assignment storage assignment = assignments[tokenId];
        if (assignment.status != AssignmentStatus.RESERVED) revert InvalidAssignmentState();
        if (block.timestamp > assignment.deadline) revert AssignmentExpired();

        ArchiveCertificateVerifierV1.PlacementCertificateV1 memory certificate =
            ArchiveCertificateVerifierV1.PlacementCertificateV1({
                tokenId: tokenId,
                requestId: assignment.requestId,
                assignmentId: assignment.assignmentId,
                attemptNonce: assignment.attemptNonce,
                groupId: assignment.groupId,
                groupKeyHash: assignment.groupKeyHash,
                genesisAcHash: genesisCertificateHash,
                membershipEpoch: assignment.membershipEpoch,
                membershipRoot: assignment.membershipRoot,
                deadline: assignment.deadline
            });
        certificateVerifier.verifyPlacementCertificate(certificate, signatures);

        assignment.status = AssignmentStatus.BOUND;
        archiveGroupId[tokenId] = assignment.groupId;
        genesisAcHash[tokenId] = genesisCertificateHash;
        genesisMembershipRoot[tokenId] = assignment.membershipRoot;
        currentMembershipEpoch[tokenId] = assignment.membershipEpoch;
        currentMembershipRoot[tokenId] = assignment.membershipRoot;
        emit ArchiveGroupBound(tokenId, assignment.groupId, assignment.assignmentId);
    }

    function expireArchiveGroupReservation(uint256 tokenId) external {
        Assignment storage assignment = assignments[tokenId];
        if (assignment.status != AssignmentStatus.RESERVED) revert InvalidAssignmentState();
        if (block.timestamp <= assignment.deadline) revert AssignmentNotExpired();
        assignment.status = AssignmentStatus.EXPIRED;
        emit ArchiveGroupReservationExpired(tokenId, assignment.groupId, assignment.attemptNonce);
    }

    function setPlacementController(address controller) external onlyOwner {
        if (controller == address(0)) revert ZeroAddress();
        placementController = controller;
        emit PlacementControllerSet(controller);
    }

    function setURI(string calldata newUri) external onlyOwner {
        _setURI(newUri);
    }

    /// @notice Records a certified membership root for the chain's current
    /// archive group. Roots only move forward and historical roots remain
    /// queryable through the group's own registry checkpoints.
    function recordMembershipCheckpoint(
        uint256 tokenId,
        uint64 membershipEpoch,
        bytes32 membershipRoot
    ) external onlyPlacementController {
        if (
            archiveGroupId[tokenId] == 0 ||
            membershipRoot == bytes32(0) ||
            membershipEpoch <= currentMembershipEpoch[tokenId]
        ) revert InvalidMembershipCheckpoint();
        currentMembershipEpoch[tokenId] = membershipEpoch;
        currentMembershipRoot[tokenId] = membershipRoot;
        emit MembershipCheckpointRecorded(tokenId, archiveGroupId[tokenId], membershipEpoch, membershipRoot);
    }

    /// @notice Commits a certificate-authorized re-home without ever deriving a
    /// destination from the NFT id. The caller is the separately configured
    /// placement/migration controller.
    function recordArchiveGroupRehome(
        uint256 tokenId,
        uint64 toGroupId,
        uint64 toMembershipEpoch,
        bytes32 toMembershipRoot,
        bytes32 migrationId
    ) external onlyPlacementController {
        uint64 fromGroupId = archiveGroupId[tokenId];
        if (
            fromGroupId == 0 ||
            toGroupId == 0 ||
            toMembershipRoot == bytes32(0) ||
            toMembershipEpoch == 0 ||
            migrationId == bytes32(0)
        ) revert InvalidMembershipCheckpoint();
        if (migrationIdUsed[migrationId]) revert DuplicateMigrationId();

        (, , , , , bool live, bool assignmentEligible) = groupRegistry.groups(toGroupId);
        if (!live || !assignmentEligible) revert GroupNotEligible();

        migrationIdUsed[migrationId] = true;
        uint64 checkpointIndex = ++migrationCount[tokenId];
        migrationCheckpoints[tokenId][checkpointIndex] = MigrationCheckpoint({
            fromGroupId: fromGroupId,
            toGroupId: toGroupId,
            fromMembershipEpoch: currentMembershipEpoch[tokenId],
            toMembershipEpoch: toMembershipEpoch,
            recordedAtBlock: uint64(block.number),
            migrationId: migrationId,
            fromMembershipRoot: currentMembershipRoot[tokenId],
            toMembershipRoot: toMembershipRoot
        });
        archiveGroupId[tokenId] = toGroupId;
        currentMembershipEpoch[tokenId] = toMembershipEpoch;
        currentMembershipRoot[tokenId] = toMembershipRoot;
        emit ArchiveGroupRehomed(tokenId, fromGroupId, toGroupId, migrationId);
        emit MembershipCheckpointRecorded(tokenId, toGroupId, toMembershipEpoch, toMembershipRoot);
    }

    /// @dev Keeps the canonical-owner registry synchronized even when a holder
    /// uses the standard ERC-1155 transfer entrypoint instead of transferChain.
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        super._update(from, to, ids, values);
        for (uint256 i; i < ids.length; ++i) {
            if (values[i] != 1) revert InvalidChainAmount();
            if (to != address(0)) chainOwner[ids[i]] = to;
        }
    }

    uint256[35] private __gap;
}
