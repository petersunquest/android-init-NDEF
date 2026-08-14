// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Parallel membership-fee config (does NOT extend Tier struct — storage-safe for existing cards).
library MembershipFeeStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.membership.fee.storage.v1");

    /// @dev Duration kinds (product month = 30d, quarter = 90d).
    uint8 internal constant DURATION_NONE = 0;
    uint8 internal constant DURATION_DAY = 1;
    uint8 internal constant DURATION_WEEK = 2;
    uint8 internal constant DURATION_MONTH = 3;
    uint8 internal constant DURATION_QUARTER = 4;
    uint8 internal constant DURATION_YEAR = 5;
    uint8 internal constant DURATION_FOREVER = 6;

    uint64 internal constant PENDING_TTL_SECONDS = 15 minutes;

    struct PendingPurchase {
        uint256 tierIndex;
        uint256 feePaid6;
        uint256 pointsCredit6;
        uint64 deadline;
        bool active;
    }

    struct Layout {
        /// @dev Parallel to `tiers[i]` — card currency E6; 0 = no membership fee for that tier.
        mapping(uint256 => uint256) feeE6;
        /// @dev Parallel duration kind per tier.
        mapping(uint256 => uint8) durationKind;
        /// @dev Staged POS first-issue / renew purchase keyed by beneficiary account (AA).
        mapping(address => PendingPurchase) pendingByAcct;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }

    function durationSeconds(uint8 kind) internal pure returns (uint256) {
        if (kind == DURATION_DAY) return 1 days;
        if (kind == DURATION_WEEK) return 7 days;
        if (kind == DURATION_MONTH) return 30 days;
        if (kind == DURATION_QUARTER) return 90 days;
        if (kind == DURATION_YEAR) return 365 days;
        // FOREVER / NONE → 0 (never expire)
        return 0;
    }

    function isValidDurationKind(uint8 kind) internal pure returns (bool) {
        return kind >= DURATION_DAY && kind <= DURATION_FOREVER;
    }
}
