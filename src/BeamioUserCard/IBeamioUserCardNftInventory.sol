// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Read-only NFT inventory hooks for BeamioUserCardViewsLib.
interface IBeamioUserCardNftInventory {
    function nftInventoryLength(address user) external view returns (uint256);
    function nftInventoryAt(address user, uint256 index) external view returns (uint256);
    function nftExpiresAt(uint256 tokenId) external view returns (uint256);
    function nftAttributes(uint256 tokenId) external view returns (uint256);
    function nftTierIndexOrMax(uint256 tokenId) external view returns (uint256);
    function pointsBalanceOf(address user) external view returns (uint256);
}
