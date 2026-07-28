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
        /// @dev upgradeType==2：发送方累计转给 admin 的 points（6 位精度）；升级成功后由模块清零
        mapping(address => uint256) cumulativePointsTransferredToAdmin6;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }
}
