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

    /// @dev Paid membership slots (base = 0, Add-tier higher = 1+). Independent of on-card `tiers[]`.
    uint256 internal constant MAX_FEE_TIERS = 16;

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

    /// @dev Fee mode is diamond `feeE6` only. Never infer from misaligned `tiers.length`.
    function isFeeMode() internal view returns (bool) {
        Layout storage l = layout();
        for (uint256 i = 0; i < MAX_FEE_TIERS; i++) {
            if (l.feeE6[i] > 0) return true;
        }
        return false;
    }

    /// @dev Highest index with feeE6 > 0, or `type(uint256).max` if none.
    function highestFeeTierIndex() internal view returns (uint256 highest) {
        Layout storage l = layout();
        highest = type(uint256).max;
        for (uint256 i = 0; i < MAX_FEE_TIERS; i++) {
            if (l.feeE6[i] > 0) highest = i;
        }
    }

    /// @dev Count of slots to report: `highest + 1`, or 0 if no fee is set.
    function feeTierCount() internal view returns (uint256) {
        uint256 highest = highestFeeTierIndex();
        return highest == type(uint256).max ? 0 : highest + 1;
    }
}
