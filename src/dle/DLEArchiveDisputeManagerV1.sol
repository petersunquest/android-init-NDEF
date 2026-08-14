// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {DLEUpgradeableBase} from "./DLEUpgradeableBase.sol";

/// @notice Bonded L1 dispute registry for archive unavailability, no-progress
/// and conflicting-finality evidence. It names exact frozen reference ACs.
contract DLEArchiveDisputeManagerV1 is DLEUpgradeableBase, ReentrancyGuardUpgradeable {
    enum Reason {
        NONE,
        NO_PROGRESS,
        UNAVAILABLE,
        CONFLICTING_FINALITY,
        EQUIVOCATION,
        BAD_ENCODING,
        REJECT_VS_ACCEPT,
        CENSORSHIP
    }

    enum Status {
        NONE,
        OPEN,
        UPHELD,
        REJECTED
    }

    struct Dispute {
        uint256 chainNftId;
        address challenger;
        uint256 bond;
        uint64 openedAt;
        uint64 resolveAfter;
        Reason reason;
        Status status;
        bytes32 evidenceHash;
        uint64 frozenAcHeight;
        bytes32 frozenAcHash;
    }

    error InvalidDispute();
    error DuplicateEvidence();
    error BondTooSmall();
    error ResolveTooEarly();
    error AlreadyResolved();
    error TransferFailed();
    error FrozenReferenceAlreadySet();

    uint64 public challengePeriod;
    uint256 public minimumBond;
    uint64 public nextDisputeId;

    mapping(uint64 => Dispute) public disputes;
    mapping(bytes32 => bool) public evidenceUsed;
    mapping(uint256 => uint64) public frozenReferenceHeight;
    mapping(uint256 => bytes32) public frozenReferenceAcHash;

    event DisputeOpened(
        uint64 indexed disputeId,
        uint256 indexed chainNftId,
        address indexed challenger,
        Reason reason,
        bytes32 evidenceHash
    );
    event DisputeResolved(
        uint64 indexed disputeId,
        Status status,
        uint64 frozenAcHeight,
        bytes32 frozenAcHash
    );
    event DisputePolicySet(uint64 challengePeriod, uint256 minimumBond);

    function initialize(
        address initialOwner,
        uint64 challengePeriod_,
        uint256 minimumBond_
    ) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        __ReentrancyGuard_init();
        challengePeriod = challengePeriod_;
        minimumBond = minimumBond_;
        nextDisputeId = 1;
    }

    function openDispute(
        uint256 chainNftId,
        Reason reason,
        bytes32 evidenceHash
    ) external payable returns (uint64 disputeId) {
        if (chainNftId == 0 || reason == Reason.NONE || evidenceHash == bytes32(0)) {
            revert InvalidDispute();
        }
        if (evidenceUsed[evidenceHash]) revert DuplicateEvidence();
        if (msg.value < minimumBond) revert BondTooSmall();

        disputeId = nextDisputeId++;
        evidenceUsed[evidenceHash] = true;
        disputes[disputeId] = Dispute({
            chainNftId: chainNftId,
            challenger: msg.sender,
            bond: msg.value,
            openedAt: uint64(block.timestamp),
            resolveAfter: uint64(block.timestamp) + challengePeriod,
            reason: reason,
            status: Status.OPEN,
            evidenceHash: evidenceHash,
            frozenAcHeight: 0,
            frozenAcHash: bytes32(0)
        });
        emit DisputeOpened(disputeId, chainNftId, msg.sender, reason, evidenceHash);
    }

    function resolveDispute(
        uint64 disputeId,
        bool upheld,
        uint64 frozenAcHeight,
        bytes32 frozenAcHash
    ) external onlyOwner nonReentrant {
        Dispute storage dispute = disputes[disputeId];
        if (dispute.status != Status.OPEN) revert AlreadyResolved();
        if (block.timestamp < dispute.resolveAfter) revert ResolveTooEarly();
        if (upheld && (frozenAcHeight == 0 || frozenAcHash == bytes32(0))) revert InvalidDispute();

        dispute.status = upheld ? Status.UPHELD : Status.REJECTED;
        dispute.frozenAcHeight = frozenAcHeight;
        dispute.frozenAcHash = frozenAcHash;
        if (upheld) {
            bytes32 existing = frozenReferenceAcHash[dispute.chainNftId];
            if (
                existing != bytes32(0) &&
                (
                    frozenReferenceHeight[dispute.chainNftId] != frozenAcHeight ||
                    existing != frozenAcHash
                )
            ) revert FrozenReferenceAlreadySet();
            frozenReferenceHeight[dispute.chainNftId] = frozenAcHeight;
            frozenReferenceAcHash[dispute.chainNftId] = frozenAcHash;
        }

        uint256 refund = dispute.bond;
        dispute.bond = 0;
        if (refund != 0) {
            (bool ok, ) = payable(dispute.challenger).call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
        emit DisputeResolved(disputeId, dispute.status, frozenAcHeight, frozenAcHash);
    }

    function isFrozenReference(
        uint256 chainNftId,
        uint64 acHeight,
        bytes32 acHash
    ) external view returns (bool) {
        return frozenReferenceHeight[chainNftId] == acHeight &&
            frozenReferenceAcHash[chainNftId] == acHash &&
            acHash != bytes32(0);
    }

    function setPolicy(uint64 challengePeriod_, uint256 minimumBond_) external onlyOwner {
        challengePeriod = challengePeriod_;
        minimumBond = minimumBond_;
        emit DisputePolicySet(challengePeriod_, minimumBond_);
    }

    uint256[44] private __gap;
}
