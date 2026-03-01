// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================================================
   IssuedNftStorage (delegatecall storage in card)
   ========================================================= */

library IssuedNftStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.issuednft.storage.v1");

    struct Layout {
        uint256 issuedNftIndex;
        mapping(uint256 => uint64) issuedNftValidAfter;
        mapping(uint256 => uint64) issuedNftValidBefore;
        mapping(uint256 => bytes32) issuedNftTitle;
        mapping(uint256 => bytes32) issuedNftSharedMetadataHash;
        mapping(uint256 => uint256) issuedNftMaxSupply;
        mapping(uint256 => uint256) issuedNftMintedCount;
        mapping(uint256 => uint256) issuedNftPriceInCurrency6;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }
}
