// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Per-card referrer registry (delegatecall-safe diamond storage).
library ReferrerStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.referrer.storage.v1");

    struct Layout {
        /// @dev Registered referee Beamio AA accounts on this card.
        mapping(address => bool) isReferee;
        /// @dev referee AA => referrer AA (single-level uplink).
        mapping(address => address) referrerOfReferee;
        /// @dev E6 ratio from charge-reward token #2 to referrer-reward token #1; 1_000_000 = 1:1; 0 = off.
        uint256 referrerRewardFromChargeRewardRatioE6;
        /// @dev All registered referee AAs (for enumeration).
        address[] registeredRefereeList;
        mapping(address => uint256) registeredRefereeIndexPlusOne;
        /// @dev Referrer AAs that currently have at least one downline referee.
        address[] referrerAccountList;
        mapping(address => uint256) referrerAccountIndexPlusOne;
        /// @dev referrer AA => downline referee AAs.
        mapping(address => address[]) refereesOfReferrer;
        mapping(address => mapping(address => uint256)) refereeIndexInReferrerPlusOne;
        /// @dev Cumulative token #0 (points) debited as payer on charge-reward transfer path (6 decimals).
        mapping(address => uint256) refereeChargePointsTotal6;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
