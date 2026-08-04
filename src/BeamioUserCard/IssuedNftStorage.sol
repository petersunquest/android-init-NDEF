// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================================================
   IssuedNftStorage (delegatecall storage in card)
   ========================================================= */

library IssuedNftStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.issuednft.storage.v1");

    struct UserContentStats {
        uint256 purchaseCount;
        uint256 purchaseAmount6;
        uint64 firstPurchaseAt;
        uint64 firstAccessAt;
        uint256 accessCount;
        uint256 trafficGB18;
    }

    struct Layout {
        uint256 issuedNftIndex;
        mapping(uint256 => uint64) issuedNftValidAfter;
        mapping(uint256 => uint64) issuedNftValidBefore;
        mapping(uint256 => bytes32) issuedNftTitle;
        mapping(uint256 => bytes32) issuedNftSharedMetadataHash;
        mapping(uint256 => uint256) issuedNftMaxSupply;
        mapping(uint256 => uint256) issuedNftMintedCount;
        mapping(uint256 => uint256) issuedNftPriceInCurrency6;
        /// @dev keyed by keccak256(abi.encode(userEOA, tokenId)): free EIP-712 path claimed once per EOA per issued series
        mapping(bytes32 => bool) issuedNftUserSigClaimUsed;
        mapping(uint256 => bool) issuedNftIsStatToken;
        mapping(uint256 => uint256) issuedNftStatParentTokenId;
        mapping(uint256 => uint8) issuedNftStatKind;
        mapping(uint256 => uint256) issuedNftAccessCount;
        mapping(uint256 => uint64) issuedNftFirstAccessAt;
        mapping(uint256 => uint256) issuedNftTrafficGB18;
        mapping(uint256 => uint256) issuedNftSalesAmount6;
        mapping(uint256 => uint256) issuedNftPurchaseCount;
        mapping(uint256 => mapping(address => UserContentStats)) issuedNftUserContentStats;
        mapping(uint256 => uint256) issuedNftShareCount;
        mapping(uint256 => uint256) issuedNftLikeCount;
        mapping(uint256 => uint256) issuedNftCommentCount;
        mapping(bytes32 => bool) issuedNftSharedByWallet;
        mapping(bytes32 => bool) issuedNftLikedByWallet;
        /// @dev Plan A social exchange: keyed by keccak256(abi.encode(userEOA, nonce))
        mapping(bytes32 => bool) usedSocialExchangeClaimSigNonces;
        /// @dev Plan A share-referee bind: keyed by keccak256(abi.encode(downlineEOA, nonce))
        mapping(bytes32 => bool) usedBindShareRefereeNonces;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }
}
