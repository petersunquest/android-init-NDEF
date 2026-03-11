// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MembershipStatsStorage.sol";
import "./BeamioUserCardBase.sol";

contract BeamioUserCardMembershipStatsModuleV1 is BeamioUserCardBase {
    constructor() BeamioUserCardBase("", address(1)) {}

    function mintMemberCardInternal(address user, uint256 tierIndex) external {
        if (user == address(0)) revert BM_ZeroAddress();
        if (tiers.length == 0 || tierIndex >= tiers.length) revert UC_MustGrow();
        address acct = _toAccount(user);
        _syncActiveToBestValidInternal(acct);
        uint256 currentActiveId = activeMembershipId[acct];
        if (currentActiveId != 0 && !_isExpired(currentActiveId)) revert UC_AlreadyHasValidCard();

        Tier memory tier = tiers[tierIndex];
        uint256 effExpiry = _effectiveExpirySeconds(tierIndex);
        uint256 expiry = effExpiry == 0 ? 0 : block.timestamp + effExpiry;
        uint256 newId = _mintMembershipNft(acct, tierIndex, tier.attr, expiry);
        _recordMembershipIssuedTotal(tierIndex);
        _activateIssuedMembership(acct, newId, tierIndex, false);
        emit AdminCardMinted(acct, newId, tier.attr, expiry);
    }

    function removeNft(address user, uint256 id) external {
        uint256[] storage list = _userOwnedNfts[user];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == id) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        if (activeMembershipId[user] == id) {
            _applyActiveTransition(user, 0, type(uint256).max);
            (uint256 bestId, uint256 bestTierIndexOrMax) = _findBestValidMembership(user);
            if (bestId != 0) _applyActiveTransition(user, bestId, bestTierIndexOrMax);
        }
    }

    function maybeUpgradeByPointsBalance(address acct) external {
        _maybeUpgradeByPointsBalanceInternal(acct);
    }

    function maybeUpgrade(address acct, uint256 pointsDelta6) external {
        _maybeUpgradeInternal(acct, pointsDelta6);
    }

    function syncActiveToBestValid(address user) external {
        _syncActiveToBestValidInternal(user);
    }

    function maybeIssueOnlyIfNoneOrExpiredByPointsDelta(address acctOrEOA, uint256 pointsDelta6) external {
        address acct = _toAccount(acctOrEOA);
        _syncActiveToBestValidInternal(acct);
        if (activeMembershipId[acct] != 0) return;
        _issueFromPointsDelta(acct, pointsDelta6);
    }

    function issueCardByPointsDelta_AssumingNoValidCard(address acct, uint256 pointsDelta6) external {
        if (activeMembershipId[acct] != 0) revert UC_AlreadyHasValidCard();
        _issueFromPointsDelta(acct, pointsDelta6);
    }

    function _recordIssueFlow(uint256 tokenId, uint256 tierIndex) internal {
        MembershipStatsStorage.Layout storage l = MembershipStatsStorage.layout();
        uint64 hourIndex = uint64(block.timestamp / 3600);
        _incrementIssue(l.hourlyGlobal[hourIndex]);
        _incrementIssue(l.hourlyByTokenId[tokenId][hourIndex]);
        if (_isTrackableTierIndex(tierIndex)) _incrementIssue(l.hourlyByTierIndex[tierIndex][hourIndex]);
    }

    function _recordUpgradeFlow(uint256 newTokenId, uint256 newTierIndex) internal {
        MembershipStatsStorage.Layout storage l = MembershipStatsStorage.layout();
        uint64 hourIndex = uint64(block.timestamp / 3600);
        _incrementUpgrade(l.hourlyGlobal[hourIndex]);
        _incrementUpgrade(l.hourlyByTokenId[newTokenId][hourIndex]);
        if (_isTrackableTierIndex(newTierIndex)) _incrementUpgrade(l.hourlyByTierIndex[newTierIndex][hourIndex]);
    }

    function _recordExpiredDiscoveryFlow(uint256 tokenId, uint256 tierIndex) internal {
        MembershipStatsStorage.Layout storage l = MembershipStatsStorage.layout();
        uint64 hourIndex = uint64(block.timestamp / 3600);
        _incrementExpired(l.hourlyGlobal[hourIndex]);
        _incrementExpired(l.hourlyByTokenId[tokenId][hourIndex]);
        if (_isTrackableTierIndex(tierIndex)) _incrementExpired(l.hourlyByTierIndex[tierIndex][hourIndex]);
    }

    function _recordActiveSwitchFlow(uint256 newTokenId, uint256 newTierIndex) internal {
        MembershipStatsStorage.Layout storage l = MembershipStatsStorage.layout();
        uint64 hourIndex = uint64(block.timestamp / 3600);
        _incrementActiveSwitch(l.hourlyGlobal[hourIndex]);
        _incrementActiveSwitch(l.hourlyByTokenId[newTokenId][hourIndex]);
        if (_isTrackableTierIndex(newTierIndex)) _incrementActiveSwitch(l.hourlyByTierIndex[newTierIndex][hourIndex]);
    }

    function _recordActivationFlow(uint256 tokenId, uint256 tierIndex) internal {
        MembershipStatsStorage.Layout storage l = MembershipStatsStorage.layout();
        uint64 hourIndex = uint64(block.timestamp / 3600);
        _incrementActivation(l.hourlyGlobal[hourIndex]);
        _incrementActivation(l.hourlyByTokenId[tokenId][hourIndex]);
        if (_isTrackableTierIndex(tierIndex)) _incrementActivation(l.hourlyByTierIndex[tierIndex][hourIndex]);
    }

    function _recordDeactivationFlow(uint256 tokenId, uint256 tierIndex) internal {
        MembershipStatsStorage.Layout storage l = MembershipStatsStorage.layout();
        uint64 hourIndex = uint64(block.timestamp / 3600);
        _incrementDeactivation(l.hourlyGlobal[hourIndex]);
        _incrementDeactivation(l.hourlyByTokenId[tokenId][hourIndex]);
        if (_isTrackableTierIndex(tierIndex)) _incrementDeactivation(l.hourlyByTierIndex[tierIndex][hourIndex]);
    }

    function _applyActiveTransition(address acct, uint256 newId, uint256 newTierIndexOrMax) internal {
        uint256 oldId = activeMembershipId[acct];
        uint256 oldTierIndexOrMax = activeTierIndexOrMax[acct];
        if (oldId == newId && oldTierIndexOrMax == newTierIndexOrMax) return;
        if (oldId != 0) _recordDeactivationFlow(oldId, oldTierIndexOrMax);
        _setActiveMembershipWithCounters(acct, newId, newTierIndexOrMax);
        if (newId != 0) _recordActivationFlow(newId, newTierIndexOrMax);
        if (oldId != 0 && newId != 0) _recordActiveSwitchFlow(newId, newTierIndexOrMax);
    }

    function _activateIssuedMembership(address acct, uint256 newId, uint256 tierIndexOrMax, bool isUpgrade) internal {
        _applyActiveTransition(acct, newId, tierIndexOrMax);
        if (isUpgrade) _recordUpgradeFlow(newId, tierIndexOrMax);
        else _recordIssueFlow(newId, tierIndexOrMax);
    }

    function _syncActiveToBestValidInternal(address user) internal {
        MembershipStatsStorage.Layout storage s = MembershipStatsStorage.layout();
        uint256[] storage nftIds = _userOwnedNfts[user];
        for (uint256 i = 0; i < nftIds.length; i++) {
            uint256 id = nftIds[i];
            if (balanceOf(user, id) == 0) continue;
            if (!_isExpired(id)) continue;
            if (s.expiredMembershipRecorded[id]) continue;
            s.expiredMembershipRecorded[id] = true;
            _recordExpiredDiscoveryFlow(id, tokenTierIndexOrMax[id]);
        }

        uint256 cur = activeMembershipId[user];
        if (cur != 0 && balanceOf(user, cur) > 0 && !_isExpired(cur)) {
            activeTierIndexOrMax[user] = tokenTierIndexOrMax[cur];
            return;
        }

        (uint256 bestId, uint256 bestTierIndexOrMax) = _findBestValidMembership(user);
        if (cur == bestId && activeTierIndexOrMax[user] == bestTierIndexOrMax) return;
        _applyActiveTransition(user, bestId, bestTierIndexOrMax);
    }

    function _issueFromPointsDelta(address acct, uint256 pointsDelta6) internal {
        if (tiers.length == 0) {
            uint256 expiry = expirySeconds == 0 ? 0 : block.timestamp + expirySeconds;
            uint256 newId = _mintMembershipNft(acct, type(uint256).max, defaultAttrWhenNoTiers, expiry);
            _recordMembershipIssuedTotal(type(uint256).max);
            emit MemberNFTIssued(acct, newId, type(uint256).max, 0, expiry);
            _activateIssuedMembership(acct, newId, type(uint256).max, false);
            return;
        }

        (bool okTier, uint256 tierIdx, uint256 attr) = _tierFromPointsDelta(pointsDelta6);
        if (!okTier) return;
        uint256 effExpiry = _effectiveExpirySeconds(tierIdx);
        uint256 expiry2 = effExpiry == 0 ? 0 : block.timestamp + effExpiry;
        uint256 newId2 = _mintMembershipNft(acct, tierIdx, attr, expiry2);
        _recordMembershipIssuedTotal(tierIdx);
        emit MemberNFTIssued(acct, newId2, tierIdx, tiers[tierIdx].minUsdc6, expiry2);
        _activateIssuedMembership(acct, newId2, tierIdx, false);
    }

    function _maybeUpgradeByPointsBalanceInternal(address acct) internal {
        if (tiers.length == 0) return;
        _syncActiveToBestValidInternal(acct);
        uint256 points = balanceOf(acct, POINTS_ID);
        (bool okTier, uint256 tierIdx, uint256 attr) = _tierFromPointsBalance(points);
        if (!okTier) return;
        uint256 currentActiveId = activeMembershipId[acct];
        if (currentActiveId == 0 || _isExpired(currentActiveId)) return;
        uint256 currentTierIdx = activeTierIndexOrMax[acct];
        if (currentTierIdx >= tiers.length) return;
        if (tiers[tierIdx].minUsdc6 <= tiers[currentTierIdx].minUsdc6) return;

        uint256 effExpiry = _effectiveExpirySeconds(tierIdx);
        uint256 expiry = effExpiry == 0 ? 0 : block.timestamp + effExpiry;
        uint256 newId = _mintMembershipNft(acct, tierIdx, attr, expiry);
        _recordMembershipIssuedTotal(tierIdx);
        _recordMembershipUpgradedTotal();
        emit MemberNFTUpgraded(acct, currentActiveId, newId, currentTierIdx, tierIdx, expiry);
        _activateIssuedMembership(acct, newId, tierIdx, true);
    }

    function _maybeUpgradeInternal(address acct, uint256 pointsDelta6) internal {
        if (tiers.length == 0) return;
        _syncActiveToBestValidInternal(acct);
        uint256 currentActiveId = activeMembershipId[acct];
        if (currentActiveId == 0 || _isExpired(currentActiveId)) return;
        uint256 currentTierIdx = activeTierIndexOrMax[acct];
        if (currentTierIdx >= tiers.length) return;

        uint256 nextTierIdx = _nextTierIndexAbove(currentTierIdx);
        if (nextTierIdx == type(uint256).max) return;
        Tier memory nextTier = tiers[nextTierIdx];
        if (nextTier.upgradeByBalance) {
            if (balanceOf(acct, POINTS_ID) < nextTier.minUsdc6) return;
        } else if (pointsDelta6 < nextTier.minUsdc6) {
            return;
        }

        uint256 effExpiry = _effectiveExpirySeconds(nextTierIdx);
        uint256 expiry = effExpiry == 0 ? 0 : block.timestamp + effExpiry;
        uint256 newId = _mintMembershipNft(acct, nextTierIdx, nextTier.attr, expiry);
        _recordMembershipIssuedTotal(nextTierIdx);
        _recordMembershipUpgradedTotal();
        emit MemberNFTUpgraded(acct, currentActiveId, newId, currentTierIdx, nextTierIdx, expiry);
        _activateIssuedMembership(acct, newId, nextTierIdx, true);
    }

    function _incrementIssue(MembershipStatsStorage.FlowBucket storage b) internal {
        if (!b.hasData) b.hasData = true;
        b.issuedCount += 1;
    }

    function _incrementUpgrade(MembershipStatsStorage.FlowBucket storage b) internal {
        if (!b.hasData) b.hasData = true;
        b.upgradedCount += 1;
    }

    function _incrementExpired(MembershipStatsStorage.FlowBucket storage b) internal {
        if (!b.hasData) b.hasData = true;
        b.expiredDiscoveredCount += 1;
    }

    function _incrementActiveSwitch(MembershipStatsStorage.FlowBucket storage b) internal {
        if (!b.hasData) b.hasData = true;
        b.activeSwitchCount += 1;
    }

    function _incrementActivation(MembershipStatsStorage.FlowBucket storage b) internal {
        if (!b.hasData) b.hasData = true;
        b.activatedCount += 1;
    }

    function _incrementDeactivation(MembershipStatsStorage.FlowBucket storage b) internal {
        if (!b.hasData) b.hasData = true;
        b.deactivatedCount += 1;
    }
}
