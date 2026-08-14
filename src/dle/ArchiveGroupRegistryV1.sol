// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {DLEUpgradeableBase} from "./DLEUpgradeableBase.sol";
import {OperatorDomainRegistryV1} from "./OperatorDomainRegistryV1.sol";

/// @notice L1 registry for disjoint 5-active + 2-dedicated-standby archive groups.
contract ArchiveGroupRegistryV1 is DLEUpgradeableBase {
    uint8 public constant ACTIVE_COUNT = 5;
    uint8 public constant STANDBY_COUNT = 2;
    uint8 public constant QUORUM = 4;

    struct Group {
        bytes32 groupKeyHash;
        bytes32 membershipRoot;
        bytes32 standbyRoot;
        uint64 membershipEpoch;
        uint64 keyEpoch;
        bool live;
        bool assignmentEligible;
    }

    struct MembershipCheckpoint {
        bytes32 membershipRoot;
        bytes32 standbyRoot;
        uint64 keyEpoch;
        uint64 activatedAtBlock;
        bool exists;
    }

    error InvalidGroupWidth();
    error InvalidMember();
    error DuplicateMember();
    error OperatorAlreadyAssigned();
    error OperatorSetNotEligible(bytes32 reasonCode);
    error UnknownGroup();
    error EpochNotIncreasing();

    OperatorDomainRegistryV1 public operatorRegistry;
    uint64 public nextGroupId;
    bytes32 public liveGroupRegistryRoot;

    mapping(uint64 => Group) public groups;
    mapping(uint64 => mapping(uint64 => MembershipCheckpoint)) public checkpoints;
    mapping(uint64 => mapping(uint64 => address[ACTIVE_COUNT])) private _activeMembers;
    mapping(uint64 => mapping(uint64 => address[STANDBY_COUNT])) private _standbyMembers;
    mapping(uint64 => bytes32[ACTIVE_COUNT + STANDBY_COUNT]) private _groupOperatorIds;
    mapping(bytes32 => uint64) public archiveGroupOfOperator;

    event GroupCreated(
        uint64 indexed groupId,
        bytes32 indexed groupKeyHash,
        uint64 membershipEpoch,
        bytes32 membershipRoot,
        bytes32 standbyRoot
    );
    event MembershipRotated(
        uint64 indexed groupId,
        uint64 indexed membershipEpoch,
        uint64 keyEpoch,
        bytes32 groupKeyHash,
        bytes32 membershipRoot,
        bytes32 standbyRoot
    );
    event GroupStatusSet(uint64 indexed groupId, bool live, bool assignmentEligible);
    event OperatorRegistrySet(address indexed registry);

    function initialize(address initialOwner, address operatorRegistry_) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        if (operatorRegistry_ == address(0)) revert ZeroAddress();
        operatorRegistry = OperatorDomainRegistryV1(operatorRegistry_);
        nextGroupId = 1;
    }

    function setOperatorRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        operatorRegistry = OperatorDomainRegistryV1(registry);
        emit OperatorRegistrySet(registry);
    }

    function createGroup(
        bytes32[ACTIVE_COUNT + STANDBY_COUNT] calldata operatorIds,
        address[ACTIVE_COUNT] calldata activeMembers,
        address[STANDBY_COUNT] calldata standbyMembers,
        bytes32 groupKeyHash,
        bytes32 membershipRoot,
        bytes32 standbyRoot,
        uint64 keyEpoch
    ) external onlyOwner returns (uint64 groupId) {
        if (
            groupKeyHash == bytes32(0) ||
            membershipRoot == bytes32(0) ||
            standbyRoot == bytes32(0) ||
            keyEpoch == 0
        ) revert InvalidMember();
        _validateCandidateSet(operatorIds, activeMembers, standbyMembers);
        groupId = nextGroupId++;
        uint64 membershipEpoch = 1;
        groups[groupId] = Group({
            groupKeyHash: groupKeyHash,
            membershipRoot: membershipRoot,
            standbyRoot: standbyRoot,
            membershipEpoch: membershipEpoch,
            keyEpoch: keyEpoch,
            live: true,
            assignmentEligible: true
        });
        _storeMembership(
            groupId,
            membershipEpoch,
            keyEpoch,
            membershipRoot,
            standbyRoot,
            operatorIds,
            activeMembers,
            standbyMembers
        );
        _mixRegistryRoot(groupId);
        emit GroupCreated(groupId, groupKeyHash, membershipEpoch, membershipRoot, standbyRoot);
    }

    function rotateMembership(
        uint64 groupId,
        bytes32[ACTIVE_COUNT + STANDBY_COUNT] calldata operatorIds,
        address[ACTIVE_COUNT] calldata activeMembers,
        address[STANDBY_COUNT] calldata standbyMembers,
        bytes32 groupKeyHash,
        bytes32 membershipRoot,
        bytes32 standbyRoot,
        uint64 keyEpoch
    ) external onlyOwner {
        Group storage group = groups[groupId];
        if (group.membershipEpoch == 0) revert UnknownGroup();
        if (keyEpoch <= group.keyEpoch) revert EpochNotIncreasing();
        if (
            groupKeyHash == bytes32(0) ||
            membershipRoot == bytes32(0) ||
            standbyRoot == bytes32(0)
        ) revert InvalidMember();

        bytes32[ACTIVE_COUNT + STANDBY_COUNT] storage oldOperators = _groupOperatorIds[groupId];
        for (uint8 i; i < ACTIVE_COUNT + STANDBY_COUNT; ++i) {
            archiveGroupOfOperator[oldOperators[i]] = 0;
        }
        _validateCandidateSet(operatorIds, activeMembers, standbyMembers);

        uint64 membershipEpoch = group.membershipEpoch + 1;
        group.membershipEpoch = membershipEpoch;
        group.keyEpoch = keyEpoch;
        group.groupKeyHash = groupKeyHash;
        group.membershipRoot = membershipRoot;
        group.standbyRoot = standbyRoot;
        _storeMembership(
            groupId,
            membershipEpoch,
            keyEpoch,
            membershipRoot,
            standbyRoot,
            operatorIds,
            activeMembers,
            standbyMembers
        );
        _mixRegistryRoot(groupId);
        emit MembershipRotated(groupId, membershipEpoch, keyEpoch, groupKeyHash, membershipRoot, standbyRoot);
    }

    function setGroupStatus(uint64 groupId, bool live, bool assignmentEligible) external onlyOwner {
        Group storage group = groups[groupId];
        if (group.membershipEpoch == 0) revert UnknownGroup();
        group.live = live;
        group.assignmentEligible = live && assignmentEligible;
        _mixRegistryRoot(groupId);
        emit GroupStatusSet(groupId, group.live, group.assignmentEligible);
    }

    function getActiveMembers(
        uint64 groupId,
        uint64 membershipEpoch
    ) external view returns (address[ACTIVE_COUNT] memory) {
        return _activeMembers[groupId][membershipEpoch];
    }

    function getStandbyMembers(
        uint64 groupId,
        uint64 membershipEpoch
    ) external view returns (address[STANDBY_COUNT] memory) {
        return _standbyMembers[groupId][membershipEpoch];
    }

    function isActiveMember(
        uint64 groupId,
        uint64 membershipEpoch,
        address member
    ) external view returns (bool) {
        address[ACTIVE_COUNT] storage members = _activeMembers[groupId][membershipEpoch];
        for (uint8 i; i < ACTIVE_COUNT; ++i) {
            if (members[i] == member) return true;
        }
        return false;
    }

    function currentCheckpoint(
        uint64 groupId
    ) external view returns (uint64 epoch, MembershipCheckpoint memory checkpoint) {
        epoch = groups[groupId].membershipEpoch;
        checkpoint = checkpoints[groupId][epoch];
    }

    /// @notice Compact current commitment used to reject certificates signed by
    /// members from a rotated or otherwise stale placement epoch.
    function currentGroupCommitment(
        uint64 groupId
    ) external view returns (uint64 membershipEpoch, bytes32 groupKeyHash, bytes32 membershipRoot) {
        Group storage group = groups[groupId];
        if (group.membershipEpoch == 0) revert UnknownGroup();
        return (group.membershipEpoch, group.groupKeyHash, group.membershipRoot);
    }

    function _validateCandidateSet(
        bytes32[ACTIVE_COUNT + STANDBY_COUNT] calldata operatorIds,
        address[ACTIVE_COUNT] calldata activeMembers,
        address[STANDBY_COUNT] calldata standbyMembers
    ) private view {
        bytes32[] memory dynamicIds = new bytes32[](ACTIVE_COUNT + STANDBY_COUNT);
        address[] memory allMembers = new address[](ACTIVE_COUNT + STANDBY_COUNT);
        for (uint8 i; i < ACTIVE_COUNT; ++i) {
            dynamicIds[i] = operatorIds[i];
            allMembers[i] = activeMembers[i];
        }
        for (uint8 i; i < STANDBY_COUNT; ++i) {
            dynamicIds[ACTIVE_COUNT + i] = operatorIds[ACTIVE_COUNT + i];
            allMembers[ACTIVE_COUNT + i] = standbyMembers[i];
        }

        (OperatorDomainRegistryV1.Decision decision, bytes32 reason) =
            operatorRegistry.evaluateCandidateSet(dynamicIds, true);
        if (decision != OperatorDomainRegistryV1.Decision.ELIGIBLE) {
            revert OperatorSetNotEligible(reason);
        }

        for (uint8 i; i < ACTIVE_COUNT + STANDBY_COUNT; ++i) {
            if (operatorIds[i] == bytes32(0) || allMembers[i] == address(0)) revert InvalidMember();
                bytes32 canonicalOperatorId = operatorRegistry.resolveCanonical(operatorIds[i]);
                if (archiveGroupOfOperator[canonicalOperatorId] != 0) revert OperatorAlreadyAssigned();
            for (uint8 j; j < i; ++j) {
                if (operatorIds[i] == operatorIds[j] || allMembers[i] == allMembers[j]) {
                    revert DuplicateMember();
                }
            }
        }
    }

    function _storeMembership(
        uint64 groupId,
        uint64 membershipEpoch,
        uint64 keyEpoch,
        bytes32 membershipRoot,
        bytes32 standbyRoot,
        bytes32[ACTIVE_COUNT + STANDBY_COUNT] calldata operatorIds,
        address[ACTIVE_COUNT] calldata activeMembers,
        address[STANDBY_COUNT] calldata standbyMembers
    ) private {
        checkpoints[groupId][membershipEpoch] = MembershipCheckpoint({
            membershipRoot: membershipRoot,
            standbyRoot: standbyRoot,
            keyEpoch: keyEpoch,
            activatedAtBlock: uint64(block.number),
            exists: true
        });
        _activeMembers[groupId][membershipEpoch] = activeMembers;
        _standbyMembers[groupId][membershipEpoch] = standbyMembers;
        for (uint8 i; i < ACTIVE_COUNT + STANDBY_COUNT; ++i) {
                bytes32 canonicalOperatorId = operatorRegistry.resolveCanonical(operatorIds[i]);
                _groupOperatorIds[groupId][i] = canonicalOperatorId;
                archiveGroupOfOperator[canonicalOperatorId] = groupId;
        }
    }

    function _mixRegistryRoot(uint64 groupId) private {
        Group storage group = groups[groupId];
        liveGroupRegistryRoot = keccak256(
            abi.encode(
                liveGroupRegistryRoot,
                groupId,
                group.groupKeyHash,
                group.membershipEpoch,
                group.membershipRoot,
                group.standbyRoot,
                group.live,
                group.assignmentEligible
            )
        );
    }

    uint256[41] private __gap;
}
