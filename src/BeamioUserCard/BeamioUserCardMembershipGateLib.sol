// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./IBeamioUserCardMembershipGateView.sol";

/// @dev Membership tier gate helpers extracted from BeamioUserCard for bytecode size (Scheme C).
/// @dev AdminStats flow recording stays on the card — namespaced storage must run in card context.
library BeamioUserCardMembershipGateLib {
    function _isExpired(IBeamioUserCardMembershipGateView card, uint256 tokenId) private view returns (bool) {
        uint256 exp = card.expiresAt(tokenId);
        return (exp != 0 && block.timestamp > exp);
    }

    function _hasValidCard(IBeamioUserCardMembershipGateView card, address acct) private view returns (bool) {
        uint256 id = card.activeMembershipId(acct);
        return (id != 0 && card.balanceOf(acct, id) > 0 && !_isExpired(card, id));
    }

    function hasValidCard(IBeamioUserCardMembershipGateView card, address acct) external view returns (bool) {
        return _hasValidCard(card, acct);
    }

    function _tierIndexWithMinThreshold(IBeamioUserCardMembershipGateView card) private view returns (uint256 idx) {
        uint256 len = card.tiersLength();
        if (len == 0) return type(uint256).max;
        idx = 0;
        (uint256 minVal,,) = card.tiers(0);
        for (uint256 i = 1; i < len; i++) {
            (uint256 m,,) = card.tiers(i);
            if (m < minVal) {
                minVal = m;
                idx = i;
            }
        }
    }

    function tierIndexWithMinThreshold(IBeamioUserCardMembershipGateView card)
        external
        view
        returns (uint256 idx)
    {
        return _tierIndexWithMinThreshold(card);
    }

    /// @dev 无有效会员且配置了 tiers 时，points mint 须 ≥ 最低档门槛，否则整笔 revert（避免先 mint points 再拒发卡）
    function requirePointsMintAllowsFirstMembership(
        IBeamioUserCardMembershipGateView card,
        address acct,
        uint256 points6
    ) external view {
        if (points6 == 0) return;
        if (_hasValidCard(card, acct)) return;
        if (card.tiersLength() == 0) return;
        uint256 lowIdx = _tierIndexWithMinThreshold(card);
        (uint256 minUsdc6,,) = card.tiers(lowIdx);
        if (points6 < minUsdc6) revert UC_BelowMinThreshold();
    }
}
