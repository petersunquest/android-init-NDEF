// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================================================
   TotalSupplyStorage (delegatecall storage in card)
   Used by BeamioUserCard for totalSupply tracking.
   Stored in a namespaced slot to avoid breaking the shared
   layout with BeamioUserCardBase (used by MembershipStatsModule).
   ========================================================= */

library TotalSupplyStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.totalsupply.storage.v1");

    struct Layout {
        mapping(uint256 => uint256) totalSupplyById;
        uint256 totalSupplyAll;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
