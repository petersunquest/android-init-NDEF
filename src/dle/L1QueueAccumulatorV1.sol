// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {DLEUpgradeableBase} from "./DLEUpgradeableBase.sol";

/// @notice Canonical ordered new-chain queue with a fixed-depth incremental
/// Merkle accumulator and O(1) range checkpoints.
contract L1QueueAccumulatorV1 is DLEUpgradeableBase {
    uint8 public constant ACCUMULATOR_DEPTH = 32;

    struct RangeCheckpoint {
        uint64 fromSeq;
        uint64 toSeq;
        uint64 futureBeaconSlot;
        uint64 l1BlockNumber;
        bytes32 queueAccumulatorRoot;
        bytes32 queueRangeHash;
        bytes32 liveGroupRegistryRoot;
        bytes32 placementPolicyId;
    }

    error EmptyCommitment();
    error DuplicateCommitment();
    error QueueFull();
    error EmptyRange();
    error InvalidRange();
    error BeaconAlreadyRevealed();
    error NoFrozenRange();
    error PreviousRangeNotProcessed();

    uint64 public nextSeq;
    uint64 public nextUnassignedSeq;
    uint64 public latestCheckpointId;
    uint64 public lastFrozenToSeq;
    bool public hasFrozenRange;
    bytes32 public queueAccumulatorRoot;

    bytes32[ACCUMULATOR_DEPTH] private _frontier;
    mapping(uint64 => bytes32) public requestCommitmentBySeq;
    mapping(bytes32 => uint64) private _seqPlusOneByCommitment;
    mapping(uint64 => RangeCheckpoint) public rangeCheckpoints;

    event RequestEnqueued(uint64 indexed seq, bytes32 indexed requestCommitment, bytes32 accumulatorRoot);
    event QueueRangeFrozen(
        uint64 indexed checkpointId,
        uint64 indexed fromSeq,
        uint64 indexed toSeq,
        bytes32 queueRangeHash,
        bytes32 accumulatorRoot,
        uint64 futureBeaconSlot
    );
    event QueueProgressAdvanced(uint64 indexed oldNextUnassignedSeq, uint64 indexed newNextUnassignedSeq);

    function initialize(address initialOwner) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        queueAccumulatorRoot = _emptyRoot();
    }

    function enqueue(bytes32 requestCommitment) external returns (uint64 seq) {
        if (requestCommitment == bytes32(0)) revert EmptyCommitment();
        if (_seqPlusOneByCommitment[requestCommitment] != 0) revert DuplicateCommitment();
        if (nextSeq == type(uint32).max) revert QueueFull();

        seq = nextSeq++;
        requestCommitmentBySeq[seq] = requestCommitment;
        _seqPlusOneByCommitment[requestCommitment] = seq + 1;
        queueAccumulatorRoot = _insert(seq, requestCommitment);
        emit RequestEnqueued(seq, requestCommitment, queueAccumulatorRoot);
    }

    function freezeUnassignedRange(
        uint64 futureBeaconSlot,
        bytes32 liveGroupRegistryRoot,
        bytes32 placementPolicyId
    ) external onlyOwner returns (uint64 checkpointId) {
        // A request must appear in at most one frozen placement range.  Partial
        // processing is allowed for a controller's local bookkeeping, but a new
        // placement commitment may not be made until the old range is complete.
        if (hasFrozenRange && nextUnassignedSeq <= lastFrozenToSeq) {
            revert PreviousRangeNotProcessed();
        }
        uint64 fromSeq = hasFrozenRange ? lastFrozenToSeq + 1 : 0;
        if (fromSeq >= nextSeq) revert EmptyRange();
        if (futureBeaconSlot <= block.number) revert BeaconAlreadyRevealed();

        uint64 toSeq = nextSeq - 1;
        bytes32 rangeHash = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                fromSeq,
                toSeq,
                queueAccumulatorRoot,
                liveGroupRegistryRoot,
                placementPolicyId,
                futureBeaconSlot
            )
        );

        checkpointId = ++latestCheckpointId;
        lastFrozenToSeq = toSeq;
        hasFrozenRange = true;
        rangeCheckpoints[checkpointId] = RangeCheckpoint({
            fromSeq: fromSeq,
            toSeq: toSeq,
            futureBeaconSlot: futureBeaconSlot,
            l1BlockNumber: uint64(block.number),
            queueAccumulatorRoot: queueAccumulatorRoot,
            queueRangeHash: rangeHash,
            liveGroupRegistryRoot: liveGroupRegistryRoot,
            placementPolicyId: placementPolicyId
        });

        emit QueueRangeFrozen(
            checkpointId,
            fromSeq,
            toSeq,
            rangeHash,
            queueAccumulatorRoot,
            futureBeaconSlot
        );
    }

    /// @notice Advances only after every request in the prefix was reserved or
    /// explicitly carried forward by the placement controller.
    function markProcessedThrough(uint64 toSeq) external onlyOwner {
        if (latestCheckpointId == 0) revert NoFrozenRange();
        if (toSeq < nextUnassignedSeq || toSeq > lastFrozenToSeq) revert InvalidRange();
        uint64 old = nextUnassignedSeq;
        nextUnassignedSeq = toSeq + 1;
        emit QueueProgressAdvanced(old, nextUnassignedSeq);
    }

    function sequenceOf(bytes32 requestCommitment) external view returns (bool exists, uint64 seq) {
        uint64 plusOne = _seqPlusOneByCommitment[requestCommitment];
        return (plusOne != 0, plusOne == 0 ? 0 : plusOne - 1);
    }

    function frontierAt(uint8 level) external view returns (bytes32) {
        return _frontier[level];
    }

    function _insert(uint64 leafIndex, bytes32 leaf) private returns (bytes32 current) {
        current = leaf;
        bytes32 zero;
        uint256 index = leafIndex;
        for (uint8 level; level < ACCUMULATOR_DEPTH; ++level) {
            if ((index & 1) == 0) {
                _frontier[level] = current;
                current = _hash(current, zero);
            } else {
                current = _hash(_frontier[level], current);
            }
            zero = _hash(zero, zero);
            index >>= 1;
        }
    }

    function _emptyRoot() private pure returns (bytes32 root) {
        for (uint8 level; level < ACCUMULATOR_DEPTH; ++level) {
            root = _hash(root, root);
        }
    }

    function _hash(bytes32 left, bytes32 right) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }

    uint256[43] private __gap;
}
