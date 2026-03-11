// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MembershipStatsStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.membership.stats.storage.v1");

    struct FlowBucket {
        uint256 issuedCount;
        uint256 upgradedCount;
        uint256 expiredDiscoveredCount;
        uint256 activeSwitchCount;
        uint256 activatedCount;
        uint256 deactivatedCount;
        bool hasData;
    }

    struct Layout {
        mapping(uint256 => bool) expiredMembershipRecorded;
        mapping(uint64 => FlowBucket) hourlyGlobal;
        mapping(uint256 => mapping(uint64 => FlowBucket)) hourlyByTokenId;
        mapping(uint256 => mapping(uint64 => FlowBucket)) hourlyByTierIndex;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }
}
