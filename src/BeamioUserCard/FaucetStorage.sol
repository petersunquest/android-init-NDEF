// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================================================
   FaucetStorage (delegatecall storage in card)
   ========================================================= */

library FaucetStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.faucet.storage.v1");

    struct FaucetConfig {
        uint64 validUntil;
        uint64 perClaimMax;
        uint128 maxPerUser;
        uint128 maxGlobal;
        bool enabled;
        uint8 currency;
        uint8 decimals;           // MUST be POINTS_DECIMALS (6)
        uint128 priceInCurrency6; // 0 free; >0 priced
    }

    struct Layout {
        mapping(uint256 => FaucetConfig) faucetConfig;
        mapping(uint256 => mapping(address => uint256)) faucetClaimed;
        mapping(uint256 => uint256) faucetGlobalMinted;
        mapping(uint256 => bool) faucetConfigFrozen;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }
}
