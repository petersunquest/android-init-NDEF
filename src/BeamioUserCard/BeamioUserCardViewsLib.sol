// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioUserCardTypes.sol";
import "./IBeamioUserCardNftInventory.sol";

/// @dev Ownership / NFT detail views (external runtime library).
library BeamioUserCardViewsLib {
    function getOwnership(IBeamioUserCardNftInventory inv, address user)
        external
        view
        returns (uint256 pt, NFTDetail[] memory nfts)
    {
        uint256 len = inv.nftInventoryLength(user);
        nfts = new NFTDetail[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = inv.nftInventoryAt(user, i);
            uint256 exp = inv.nftExpiresAt(id);
            bool expired = (exp != 0 && block.timestamp > exp);
            nfts[i] = NFTDetail(id, inv.nftAttributes(id), inv.nftTierIndexOrMax(id), exp, expired);
        }
        return (inv.pointsBalanceOf(user), nfts);
    }
}
