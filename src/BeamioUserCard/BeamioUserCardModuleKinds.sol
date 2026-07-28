// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Shared module kind ids for Factory registry and BeamioUserCard routing.
library BeamioUserCardModuleKinds {
    uint8 internal constant REDEEM = 0;
    uint8 internal constant FAUCET = 1;
    uint8 internal constant ISSUED_NFT = 2;
    uint8 internal constant GOVERNANCE = 3;
    uint8 internal constant MEMBERSHIP_STATS = 4;
    uint8 internal constant CHARGE_REWARD = 5;
    /// @dev Must match AdminStatsQueryModule ROUTE_STATS_QUERY and card ROUTE_STATS_QUERY.
    uint8 internal constant STATS_QUERY = type(uint8).max - 1;
}
