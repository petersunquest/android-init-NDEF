// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Per-card referrer registry (delegatecall-safe diamond storage).
library ReferrerStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.referrer.storage.v1");

    /// @dev Cumulative #13 rewards + fiat bases for referrer→referee (UI: topup/charge[referrer][referee]).
    struct ReferrerRefereeLedger {
        uint256 topupReward13E6;
        uint256 chargeReward13E6;
        uint256 topupAmountFiat6;
        uint256 chargeAmountFiat6;
    }

    struct Layout {
        /// @dev Registered referee accounts on this card (canonical: EOA; legacy rows may be AA).
        mapping(address => bool) isReferee;
        /// @dev downline => referrer uplink (canonical: EOA; legacy rows may be AA).
        mapping(address => address) referrerOfReferee;
        /// @dev E6 ratio of **charge amountFiat6** → referrer #13; 1_000_000 = 100%; 0 = off.
        ///      (Storage name kept for slot stability; product base is charge amount, not legacy #2.)
        uint256 referrerRewardFromChargeRewardRatioE6;
        /// @dev All registered referees (for enumeration).
        address[] registeredRefereeList;
        mapping(address => uint256) registeredRefereeIndexPlusOne;
        /// @dev Referrers that currently have at least one downline referee.
        address[] referrerAccountList;
        mapping(address => uint256) referrerAccountIndexPlusOne;
        /// @dev referrer => downline referees.
        mapping(address => address[]) refereesOfReferrer;
        mapping(address => mapping(address => uint256)) refereeIndexInReferrerPlusOne;
        /// @dev Cumulative token #0 (points) debited as payer on charge path (6 decimals).
        mapping(address => uint256) refereeChargePointsTotal6;
        /// @dev E6 ratio of **top-up amountFiat6** → referrer #13; 1_000_000 = 100%; 0 = off.
        uint256 referrerRewardFromTopupAmountRatioE6;
        /// @dev referrer => referee => ledger (canonical EOA keys preferred).
        mapping(address => mapping(address => ReferrerRefereeLedger)) referrerRefereeLedger;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
