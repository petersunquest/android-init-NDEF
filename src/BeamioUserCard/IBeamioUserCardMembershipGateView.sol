// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Read-only surface for BeamioUserCardMembershipGateLib (card passes address(this)).
interface IBeamioUserCardMembershipGateView {
    function balanceOf(address account, uint256 id) external view returns (uint256);

    function activeMembershipId(address acct) external view returns (uint256);

    function expiresAt(uint256 tokenId) external view returns (uint256);

    function tiersLength() external view returns (uint256);

    function tiers(uint256 index)
        external
        view
        returns (uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds);
}
