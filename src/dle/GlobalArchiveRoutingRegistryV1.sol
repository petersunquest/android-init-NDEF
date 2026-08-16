// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {DLEUpgradeableBase} from "./DLEUpgradeableBase.sol";

/// @notice CoNET L1 Global Archive Routing Registry (whitepaper §5.2.0d).
/// @dev Canonical address is the UUPS proxy. Stores live group ids, the seven
/// participant archive EOAs per group, and hosted chain NFT ids. Does not store
/// explorer hostnames or lab EVM chain ids.
contract GlobalArchiveRoutingRegistryV1 is DLEUpgradeableBase {
    uint8 public constant ACTIVE_COUNT = 5;
    uint8 public constant STANDBY_COUNT = 2;
    uint8 public constant ARCHIVE_COUNT = 7;
    uint64 public constant VERSION = 1;

    struct GroupRecord {
        bool live;
        bool assignmentEligible;
        uint64 membershipEpoch;
        uint64 keyEpoch;
        bytes32 groupKeyHash;
        bytes32 membershipRoot;
        bytes32 standbyRoot;
    }

    error InvalidGroupWidth();
    error InvalidMember();
    error DuplicateMember();
    error WalletAlreadyAssigned();
    error UnknownGroup();
    error UnknownChain();
    error ChainAlreadyBound();
    error EpochNotIncreasing();
    error InvalidCommitment();

    uint64 public nextGroupId;

    mapping(uint64 => GroupRecord) private _groups;
    mapping(uint64 => mapping(uint64 => address[ARCHIVE_COUNT])) private _archivesByEpoch;
    mapping(address => uint64) public groupOfWallet;
    mapping(uint256 => uint64) public archiveGroupId;
    mapping(uint64 => uint256[]) private _hostedChains;
    mapping(uint256 => uint256) private _hostedIndexPlusOne;

    event GroupRegistered(
        uint64 indexed groupId,
        uint64 membershipEpoch,
        bytes32 groupKeyHash,
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
    event ChainBound(uint256 indexed chainNftId, uint64 indexed groupId);
    event ChainUnbound(uint256 indexed chainNftId, uint64 indexed groupId);
    event ChainRehomed(uint256 indexed chainNftId, uint64 indexed fromGroupId, uint64 indexed toGroupId);

    function initialize(address initialOwner) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        nextGroupId = 1;
    }

    function version() external pure returns (uint64) {
        return VERSION;
    }

    function registerLiveGroup(
        address[ACTIVE_COUNT] calldata activeWallets,
        address[STANDBY_COUNT] calldata standbyWallets,
        bytes32 groupKeyHash,
        bytes32 membershipRoot,
        bytes32 standbyRoot,
        uint64 keyEpoch
    ) external onlyOwner returns (uint64 groupId) {
        _assertCommitments(groupKeyHash, membershipRoot, standbyRoot, keyEpoch);
        address[ARCHIVE_COUNT] memory archives = _packArchives(activeWallets, standbyWallets);
        _assertUniqueUnassigned(archives);

        groupId = nextGroupId++;
        uint64 membershipEpoch = 1;
        _groups[groupId] = GroupRecord({
            live: true,
            assignmentEligible: true,
            membershipEpoch: membershipEpoch,
            keyEpoch: keyEpoch,
            groupKeyHash: groupKeyHash,
            membershipRoot: membershipRoot,
            standbyRoot: standbyRoot
        });
        _storeArchives(groupId, membershipEpoch, archives);
        emit GroupRegistered(groupId, membershipEpoch, groupKeyHash, membershipRoot, standbyRoot);
    }

    function rotateMembership(
        uint64 groupId,
        address[ACTIVE_COUNT] calldata activeWallets,
        address[STANDBY_COUNT] calldata standbyWallets,
        bytes32 groupKeyHash,
        bytes32 membershipRoot,
        bytes32 standbyRoot,
        uint64 keyEpoch
    ) external onlyOwner {
        GroupRecord storage group = _groups[groupId];
        if (group.membershipEpoch == 0) revert UnknownGroup();
        if (keyEpoch <= group.keyEpoch) revert EpochNotIncreasing();
        _assertCommitments(groupKeyHash, membershipRoot, standbyRoot, keyEpoch);

        address[ARCHIVE_COUNT] memory nextArchives = _packArchives(activeWallets, standbyWallets);
        address[ARCHIVE_COUNT] storage previous = _archivesByEpoch[groupId][group.membershipEpoch];
        for (uint8 i; i < ARCHIVE_COUNT; ++i) {
            groupOfWallet[previous[i]] = 0;
        }
        _assertUniqueUnassigned(nextArchives);

        uint64 membershipEpoch = group.membershipEpoch + 1;
        group.membershipEpoch = membershipEpoch;
        group.keyEpoch = keyEpoch;
        group.groupKeyHash = groupKeyHash;
        group.membershipRoot = membershipRoot;
        group.standbyRoot = standbyRoot;
        _storeArchives(groupId, membershipEpoch, nextArchives);
        emit MembershipRotated(groupId, membershipEpoch, keyEpoch, groupKeyHash, membershipRoot, standbyRoot);
    }

    function setGroupStatus(uint64 groupId, bool live, bool assignmentEligible) external onlyOwner {
        GroupRecord storage group = _groups[groupId];
        if (group.membershipEpoch == 0) revert UnknownGroup();
        group.live = live;
        group.assignmentEligible = live && assignmentEligible;
        emit GroupStatusSet(groupId, group.live, group.assignmentEligible);
    }

    function bindChain(uint256 chainNftId, uint64 groupId) external onlyOwner {
        _bindChain(chainNftId, groupId);
        emit ChainBound(chainNftId, groupId);
    }

    function unbindChain(uint256 chainNftId) external onlyOwner {
        uint64 groupId = _unbindChain(chainNftId);
        emit ChainUnbound(chainNftId, groupId);
    }

    function rehomeChain(uint256 chainNftId, uint64 toGroupId) external onlyOwner {
        uint64 fromGroupId = _unbindChain(chainNftId);
        _bindChain(chainNftId, toGroupId);
        emit ChainRehomed(chainNftId, fromGroupId, toGroupId);
    }

    function liveGroupIds() external view returns (uint64[] memory ids) {
        uint64 maxId = nextGroupId == 0 ? 0 : nextGroupId - 1;
        uint64 count;
        for (uint64 i = 1; i <= maxId; ++i) {
            if (_groups[i].live) ++count;
        }
        ids = new uint64[](count);
        uint64 written;
        for (uint64 i = 1; i <= maxId; ++i) {
            if (_groups[i].live) {
                ids[written] = i;
                ++written;
            }
        }
    }

    function archivesOf(uint64 groupId) external view returns (address[ARCHIVE_COUNT] memory) {
        GroupRecord storage group = _groups[groupId];
        if (group.membershipEpoch == 0) revert UnknownGroup();
        return _archivesByEpoch[groupId][group.membershipEpoch];
    }

    function archivesOfAt(
        uint64 groupId,
        uint64 membershipEpoch
    ) external view returns (address[ARCHIVE_COUNT] memory archives) {
        if (_groups[groupId].membershipEpoch == 0) revert UnknownGroup();
        archives = _archivesByEpoch[groupId][membershipEpoch];
        if (archives[0] == address(0)) revert UnknownGroup();
    }

    function chainsOf(uint64 groupId) external view returns (uint256[] memory) {
        if (_groups[groupId].membershipEpoch == 0) revert UnknownGroup();
        return _hostedChains[groupId];
    }

    function route(uint256 chainNftId) external view returns (uint64 groupId) {
        groupId = archiveGroupId[chainNftId];
        if (groupId == 0) revert UnknownChain();
    }

    function historyProviders(uint256 chainNftId) external view returns (address[ARCHIVE_COUNT] memory) {
        uint64 groupId = archiveGroupId[chainNftId];
        if (groupId == 0) revert UnknownChain();
        return _archivesByEpoch[groupId][_groups[groupId].membershipEpoch];
    }

    function groupRecord(uint64 groupId) external view returns (GroupRecord memory) {
        GroupRecord memory group = _groups[groupId];
        if (group.membershipEpoch == 0) revert UnknownGroup();
        return group;
    }

    function _assertCommitments(
        bytes32 groupKeyHash,
        bytes32 membershipRoot,
        bytes32 standbyRoot,
        uint64 keyEpoch
    ) private pure {
        if (
            groupKeyHash == bytes32(0) ||
            membershipRoot == bytes32(0) ||
            standbyRoot == bytes32(0) ||
            keyEpoch == 0
        ) revert InvalidCommitment();
    }

    function _packArchives(
        address[ACTIVE_COUNT] calldata activeWallets,
        address[STANDBY_COUNT] calldata standbyWallets
    ) private pure returns (address[ARCHIVE_COUNT] memory archives) {
        for (uint8 i; i < ACTIVE_COUNT; ++i) {
            archives[i] = activeWallets[i];
        }
        for (uint8 i; i < STANDBY_COUNT; ++i) {
            archives[ACTIVE_COUNT + i] = standbyWallets[i];
        }
    }

    function _assertUniqueUnassigned(address[ARCHIVE_COUNT] memory archives) private view {
        for (uint8 i; i < ARCHIVE_COUNT; ++i) {
            address wallet = archives[i];
            if (wallet == address(0)) revert InvalidMember();
            if (groupOfWallet[wallet] != 0) revert WalletAlreadyAssigned();
            for (uint8 j; j < i; ++j) {
                if (archives[j] == wallet) revert DuplicateMember();
            }
        }
    }

    function _storeArchives(
        uint64 groupId,
        uint64 membershipEpoch,
        address[ARCHIVE_COUNT] memory archives
    ) private {
        _archivesByEpoch[groupId][membershipEpoch] = archives;
        for (uint8 i; i < ARCHIVE_COUNT; ++i) {
            groupOfWallet[archives[i]] = groupId;
        }
    }

    function _bindChain(uint256 chainNftId, uint64 groupId) private {
        if (chainNftId == 0) revert UnknownChain();
        GroupRecord storage group = _groups[groupId];
        if (group.membershipEpoch == 0) revert UnknownGroup();
        if (archiveGroupId[chainNftId] != 0) revert ChainAlreadyBound();
        archiveGroupId[chainNftId] = groupId;
        _hostedChains[groupId].push(chainNftId);
        _hostedIndexPlusOne[chainNftId] = _hostedChains[groupId].length;
    }

    function _unbindChain(uint256 chainNftId) private returns (uint64 groupId) {
        groupId = archiveGroupId[chainNftId];
        if (groupId == 0) revert UnknownChain();
        uint256[] storage hosted = _hostedChains[groupId];
        uint256 index = _hostedIndexPlusOne[chainNftId] - 1;
        uint256 last = hosted.length - 1;
        if (index != last) {
            uint256 moved = hosted[last];
            hosted[index] = moved;
            _hostedIndexPlusOne[moved] = index + 1;
        }
        hosted.pop();
        delete _hostedIndexPlusOne[chainNftId];
        delete archiveGroupId[chainNftId];
    }

    uint256[42] private __gap;
}
