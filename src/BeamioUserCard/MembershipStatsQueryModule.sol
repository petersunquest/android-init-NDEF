// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBeamioMembershipStatsCardView {
    function membershipFlowBucketAtHour(uint64 hourIndex)
        external
        view
        returns (
            uint256 issuedCount,
            uint256 upgradedCount,
            uint256 expiredDiscoveredCount,
            uint256 activeSwitchCount,
            uint256 activatedCount,
            uint256 deactivatedCount,
            bool hasData
        );

    function membershipScopedFlowBucketAtHour(uint8 scopeType, uint256 scopeKey, uint64 hourIndex)
        external
        view
        returns (
            uint256 issuedCount,
            uint256 upgradedCount,
            uint256 expiredDiscoveredCount,
            uint256 activeSwitchCount,
            uint256 activatedCount,
            uint256 deactivatedCount,
            bool hasData
        );

    function totalActiveMemberships() external view returns (uint256);
    function activeMembershipCountByTokenId(uint256 tokenId) external view returns (uint256);
    function activeMembershipCountByTierIndex(uint256 tierIndex) external view returns (uint256);
}

contract BeamioUserCardMembershipStatsQueryModuleV1 {
    uint8 internal constant PERIOD_HOUR = 0;
    uint8 internal constant PERIOD_DAY = 1;
    uint8 internal constant PERIOD_WEEK = 2;
    uint8 internal constant PERIOD_MONTH = 3;
    uint8 internal constant PERIOD_QUARTER = 4;
    uint8 internal constant PERIOD_YEAR = 5;
    uint8 internal constant SCOPE_TOKEN = 1;
    uint8 internal constant SCOPE_TIER = 2;

    function getMembershipFlowStatsByCurrentPeriodOffset(address card, uint8 periodType, uint256 periodOffset)
        external
        view
        returns (
            uint256 issuedCount,
            uint256 upgradedCount,
            uint256 expiredDiscoveredCount,
            uint256 activeSwitchCount,
            uint256 periodStart,
            uint256 periodEnd
        )
    {
        return _getCurrentPeriodFlowStats(card, periodType, periodOffset);
    }

    function getMembershipFlowStatsByCurrentPeriodOffsetAndTokenId(
        address card,
        uint256 tokenId,
        uint8 periodType,
        uint256 periodOffset
    )
        external
        view
        returns (
            uint256 issuedCount,
            uint256 upgradedCount,
            uint256 expiredDiscoveredCount,
            uint256 activeSwitchCount,
            uint256 periodStart,
            uint256 periodEnd
        )
    {
        return _getCurrentPeriodFlowStatsByTokenId(card, tokenId, periodType, periodOffset);
    }

    function getMembershipFlowStatsByCurrentPeriodOffsetAndTierIndex(
        address card,
        uint256 tierIndex,
        uint8 periodType,
        uint256 periodOffset
    )
        external
        view
        returns (
            uint256 issuedCount,
            uint256 upgradedCount,
            uint256 expiredDiscoveredCount,
            uint256 activeSwitchCount,
            uint256 periodStart,
            uint256 periodEnd
        )
    {
        return _getCurrentPeriodFlowStatsByTierIndex(card, tierIndex, periodType, periodOffset);
    }

    function getMembershipActiveStatsByCurrentPeriodOffset(address card, uint8 periodType, uint256 periodOffset)
        external
        view
        returns (
            uint256 periodStartActiveCount,
            uint256 periodEndActiveCount,
            uint256 activatedCount,
            uint256 deactivatedCount,
            uint256 periodStart,
            uint256 periodEnd
        )
    {
        return _getCurrentPeriodActiveStats(card, 0, 0, periodType, periodOffset);
    }

    function getMembershipActiveStatsByCurrentPeriodOffsetAndTokenId(
        address card,
        uint256 tokenId,
        uint8 periodType,
        uint256 periodOffset
    )
        external
        view
        returns (
            uint256 periodStartActiveCount,
            uint256 periodEndActiveCount,
            uint256 activatedCount,
            uint256 deactivatedCount,
            uint256 periodStart,
            uint256 periodEnd
        )
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TOKEN, tokenId, periodType, periodOffset);
    }

    function getMembershipActiveStatsByCurrentPeriodOffsetAndTierIndex(
        address card,
        uint256 tierIndex,
        uint8 periodType,
        uint256 periodOffset
    )
        external
        view
        returns (
            uint256 periodStartActiveCount,
            uint256 periodEndActiveCount,
            uint256 activatedCount,
            uint256 deactivatedCount,
            uint256 periodStart,
            uint256 periodEnd
        )
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TIER, tierIndex, periodType, periodOffset);
    }

    function getMembershipFlowStatsByHourOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStats(card, PERIOD_HOUR, periodOffset);
    }

    function getMembershipFlowStatsByDayOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStats(card, PERIOD_DAY, periodOffset);
    }

    function getMembershipFlowStatsByWeekOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStats(card, PERIOD_WEEK, periodOffset);
    }

    function getMembershipFlowStatsByMonthOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStats(card, PERIOD_MONTH, periodOffset);
    }

    function getMembershipFlowStatsByQuarterOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStats(card, PERIOD_QUARTER, periodOffset);
    }

    function getMembershipFlowStatsByYearOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStats(card, PERIOD_YEAR, periodOffset);
    }

    function getMembershipFlowStatsByHourOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTokenId(card, tokenId, PERIOD_HOUR, periodOffset);
    }

    function getMembershipFlowStatsByDayOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTokenId(card, tokenId, PERIOD_DAY, periodOffset);
    }

    function getMembershipFlowStatsByWeekOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTokenId(card, tokenId, PERIOD_WEEK, periodOffset);
    }

    function getMembershipFlowStatsByMonthOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTokenId(card, tokenId, PERIOD_MONTH, periodOffset);
    }

    function getMembershipFlowStatsByQuarterOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTokenId(card, tokenId, PERIOD_QUARTER, periodOffset);
    }

    function getMembershipFlowStatsByYearOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTokenId(card, tokenId, PERIOD_YEAR, periodOffset);
    }

    function getMembershipFlowStatsByHourOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTierIndex(card, tierIndex, PERIOD_HOUR, periodOffset);
    }

    function getMembershipFlowStatsByDayOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTierIndex(card, tierIndex, PERIOD_DAY, periodOffset);
    }

    function getMembershipFlowStatsByWeekOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTierIndex(card, tierIndex, PERIOD_WEEK, periodOffset);
    }

    function getMembershipFlowStatsByMonthOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTierIndex(card, tierIndex, PERIOD_MONTH, periodOffset);
    }

    function getMembershipFlowStatsByQuarterOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTierIndex(card, tierIndex, PERIOD_QUARTER, periodOffset);
    }

    function getMembershipFlowStatsByYearOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodFlowStatsByTierIndex(card, tierIndex, PERIOD_YEAR, periodOffset);
    }

    function getMembershipActiveStatsByHourOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, 0, 0, PERIOD_HOUR, periodOffset);
    }

    function getMembershipActiveStatsByDayOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, 0, 0, PERIOD_DAY, periodOffset);
    }

    function getMembershipActiveStatsByWeekOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, 0, 0, PERIOD_WEEK, periodOffset);
    }

    function getMembershipActiveStatsByMonthOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, 0, 0, PERIOD_MONTH, periodOffset);
    }

    function getMembershipActiveStatsByQuarterOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, 0, 0, PERIOD_QUARTER, periodOffset);
    }

    function getMembershipActiveStatsByYearOffset(address card, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, 0, 0, PERIOD_YEAR, periodOffset);
    }

    function getMembershipActiveStatsByHourOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TOKEN, tokenId, PERIOD_HOUR, periodOffset);
    }

    function getMembershipActiveStatsByDayOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TOKEN, tokenId, PERIOD_DAY, periodOffset);
    }

    function getMembershipActiveStatsByWeekOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TOKEN, tokenId, PERIOD_WEEK, periodOffset);
    }

    function getMembershipActiveStatsByMonthOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TOKEN, tokenId, PERIOD_MONTH, periodOffset);
    }

    function getMembershipActiveStatsByQuarterOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TOKEN, tokenId, PERIOD_QUARTER, periodOffset);
    }

    function getMembershipActiveStatsByYearOffsetAndTokenId(address card, uint256 tokenId, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TOKEN, tokenId, PERIOD_YEAR, periodOffset);
    }

    function getMembershipActiveStatsByHourOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TIER, tierIndex, PERIOD_HOUR, periodOffset);
    }

    function getMembershipActiveStatsByDayOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TIER, tierIndex, PERIOD_DAY, periodOffset);
    }

    function getMembershipActiveStatsByWeekOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TIER, tierIndex, PERIOD_WEEK, periodOffset);
    }

    function getMembershipActiveStatsByMonthOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TIER, tierIndex, PERIOD_MONTH, periodOffset);
    }

    function getMembershipActiveStatsByQuarterOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TIER, tierIndex, PERIOD_QUARTER, periodOffset);
    }

    function getMembershipActiveStatsByYearOffsetAndTierIndex(address card, uint256 tierIndex, uint256 periodOffset)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return _getCurrentPeriodActiveStats(card, SCOPE_TIER, tierIndex, PERIOD_YEAR, periodOffset);
    }

    function _getCurrentPeriodFlowStats(address card, uint8 periodType, uint256 periodOffset)
        internal
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        require(card != address(0), "card=0");
        require(_isValidPeriodType(periodType), "bad periodType");
        uint256 currentStart;
        (currentStart, ) = _resolvePeriodRange(block.timestamp, periodType);
        uint256 periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        uint256 periodEnd = _periodEndFromStart(periodStart, periodType);
        return _aggregateCard(card, periodStart, periodEnd);
    }

    function _getCurrentPeriodFlowStatsByTokenId(address card, uint256 tokenId, uint8 periodType, uint256 periodOffset)
        internal
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        require(card != address(0), "card=0");
        require(_isValidPeriodType(periodType), "bad periodType");
        uint256 currentStart;
        (currentStart, ) = _resolvePeriodRange(block.timestamp, periodType);
        uint256 periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        uint256 periodEnd = _periodEndFromStart(periodStart, periodType);
        return _aggregateCardByTokenId(card, tokenId, periodStart, periodEnd);
    }

    function _getCurrentPeriodFlowStatsByTierIndex(address card, uint256 tierIndex, uint8 periodType, uint256 periodOffset)
        internal
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        require(card != address(0), "card=0");
        require(_isValidPeriodType(periodType), "bad periodType");
        uint256 currentStart;
        (currentStart, ) = _resolvePeriodRange(block.timestamp, periodType);
        uint256 periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        uint256 periodEnd = _periodEndFromStart(periodStart, periodType);
        return _aggregateCardByTierIndex(card, tierIndex, periodStart, periodEnd);
    }

    function _getCurrentPeriodActiveStats(address card, uint8 scopeType, uint256 scopeKey, uint8 periodType, uint256 periodOffset)
        internal
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        require(card != address(0), "card=0");
        require(_isValidPeriodType(periodType), "bad periodType");
        uint256 currentStart;
        (currentStart, ) = _resolvePeriodRange(block.timestamp, periodType);
        uint256 periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        uint256 periodEnd = _periodEndFromStart(periodStart, periodType);
        (uint256 activatedCount, uint256 deactivatedCount) =
            _aggregateActiveDeltas(card, scopeType, scopeKey, periodStart, periodEnd);
        uint256 periodEndActiveCount = _activeCountAtPeriodEnd(card, scopeType, scopeKey, periodEnd);
        uint256 periodStartActiveCount = periodEndActiveCount + deactivatedCount - activatedCount;
        return (periodStartActiveCount, periodEndActiveCount, activatedCount, deactivatedCount, periodStart, periodEnd);
    }

    function _aggregateCard(address card, uint256 periodStart, uint256 periodEnd)
        internal
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        IBeamioMembershipStatsCardView c = IBeamioMembershipStatsCardView(card);
        uint256 issuedCount;
        uint256 upgradedCount;
        uint256 expiredDiscoveredCount;
        uint256 activeSwitchCount;
        uint64 startHour = uint64(periodStart / 3600);
        uint64 endHour = uint64(periodEnd / 3600);
        for (uint64 hourIndex = startHour; hourIndex <= endHour; hourIndex++) {
            (uint256 issued_, uint256 upgraded_, uint256 expired_, uint256 switched_, , , bool hasData) =
                c.membershipFlowBucketAtHour(hourIndex);
            if (!hasData) continue;
            issuedCount += issued_;
            upgradedCount += upgraded_;
            expiredDiscoveredCount += expired_;
            activeSwitchCount += switched_;
        }
        return (issuedCount, upgradedCount, expiredDiscoveredCount, activeSwitchCount, periodStart, periodEnd);
    }

    function _aggregateCardByTokenId(address card, uint256 tokenId, uint256 periodStart, uint256 periodEnd)
        internal
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        IBeamioMembershipStatsCardView c = IBeamioMembershipStatsCardView(card);
        uint256 issuedCount;
        uint256 upgradedCount;
        uint256 expiredDiscoveredCount;
        uint256 activeSwitchCount;
        uint64 startHour = uint64(periodStart / 3600);
        uint64 endHour = uint64(periodEnd / 3600);
        for (uint64 hourIndex = startHour; hourIndex <= endHour; hourIndex++) {
            (uint256 issued_, uint256 upgraded_, uint256 expired_, uint256 switched_, , , bool hasData) =
                c.membershipScopedFlowBucketAtHour(SCOPE_TOKEN, tokenId, hourIndex);
            if (!hasData) continue;
            issuedCount += issued_;
            upgradedCount += upgraded_;
            expiredDiscoveredCount += expired_;
            activeSwitchCount += switched_;
        }
        return (issuedCount, upgradedCount, expiredDiscoveredCount, activeSwitchCount, periodStart, periodEnd);
    }

    function _aggregateCardByTierIndex(address card, uint256 tierIndex, uint256 periodStart, uint256 periodEnd)
        internal
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        IBeamioMembershipStatsCardView c = IBeamioMembershipStatsCardView(card);
        uint256 issuedCount;
        uint256 upgradedCount;
        uint256 expiredDiscoveredCount;
        uint256 activeSwitchCount;
        uint64 startHour = uint64(periodStart / 3600);
        uint64 endHour = uint64(periodEnd / 3600);
        for (uint64 hourIndex = startHour; hourIndex <= endHour; hourIndex++) {
            (uint256 issued_, uint256 upgraded_, uint256 expired_, uint256 switched_, , , bool hasData) =
                c.membershipScopedFlowBucketAtHour(SCOPE_TIER, tierIndex, hourIndex);
            if (!hasData) continue;
            issuedCount += issued_;
            upgradedCount += upgraded_;
            expiredDiscoveredCount += expired_;
            activeSwitchCount += switched_;
        }
        return (issuedCount, upgradedCount, expiredDiscoveredCount, activeSwitchCount, periodStart, periodEnd);
    }

    function _aggregateActiveDeltas(address card, uint8 scopeType, uint256 scopeKey, uint256 periodStart, uint256 periodEnd)
        internal
        view
        returns (uint256 activatedCount, uint256 deactivatedCount)
    {
        IBeamioMembershipStatsCardView c = IBeamioMembershipStatsCardView(card);
        uint64 startHour = uint64(periodStart / 3600);
        uint64 endHour = uint64(periodEnd / 3600);
        for (uint64 hourIndex = startHour; hourIndex <= endHour; hourIndex++) {
            uint256 activated_;
            uint256 deactivated_;
            bool hasData;
            if (scopeType == 0) {
                (, , , , activated_, deactivated_, hasData) = c.membershipFlowBucketAtHour(hourIndex);
            } else {
                (, , , , activated_, deactivated_, hasData) = c.membershipScopedFlowBucketAtHour(scopeType, scopeKey, hourIndex);
            }
            if (!hasData) continue;
            activatedCount += activated_;
            deactivatedCount += deactivated_;
        }
    }

    function _activeCountAtPeriodEnd(address card, uint8 scopeType, uint256 scopeKey, uint256 periodEnd)
        internal
        view
        returns (uint256)
    {
        IBeamioMembershipStatsCardView c = IBeamioMembershipStatsCardView(card);
        int256 active = int256(_currentActiveCount(c, scopeType, scopeKey));
        uint64 endHour = uint64(periodEnd / 3600);
        uint64 currentHour = uint64(block.timestamp / 3600);
        for (uint64 hourIndex = endHour + 1; hourIndex <= currentHour; hourIndex++) {
            uint256 activated_;
            uint256 deactivated_;
            bool hasData;
            if (scopeType == 0) {
                (, , , , activated_, deactivated_, hasData) = c.membershipFlowBucketAtHour(hourIndex);
            } else {
                (, , , , activated_, deactivated_, hasData) = c.membershipScopedFlowBucketAtHour(scopeType, scopeKey, hourIndex);
            }
            if (!hasData) continue;
            active += int256(deactivated_) - int256(activated_);
        }
        return active <= 0 ? 0 : uint256(active);
    }

    function _currentActiveCount(IBeamioMembershipStatsCardView c, uint8 scopeType, uint256 scopeKey)
        internal
        view
        returns (uint256)
    {
        if (scopeType == 0) return c.totalActiveMemberships();
        if (scopeType == SCOPE_TOKEN) return c.activeMembershipCountByTokenId(scopeKey);
        return c.activeMembershipCountByTierIndex(scopeKey);
    }

    function _isValidPeriodType(uint8 periodType) internal pure returns (bool) {
        return
            periodType == PERIOD_HOUR ||
            periodType == PERIOD_DAY ||
            periodType == PERIOD_WEEK ||
            periodType == PERIOD_MONTH ||
            periodType == PERIOD_QUARTER ||
            periodType == PERIOD_YEAR;
    }

    function _shiftPeriodStartBack(uint256 startTs, uint8 periodType, uint256 periodOffset) internal pure returns (uint256) {
        if (periodOffset == 0) return startTs;
        if (periodType == PERIOD_HOUR) return startTs - (periodOffset * 1 hours);
        if (periodType == PERIOD_DAY) return startTs - (periodOffset * 1 days);
        if (periodType == PERIOD_WEEK) return startTs - (periodOffset * 7 days);
        uint256 s = startTs;
        for (uint256 i = 0; i < periodOffset; i++) s = _previousPeriodStart(s, periodType);
        return s;
    }

    function _periodEndFromStart(uint256 startTs, uint8 periodType) internal pure returns (uint256) {
        if (periodType == PERIOD_HOUR) return startTs + 1 hours - 1;
        if (periodType == PERIOD_DAY) return startTs + 1 days - 1;
        if (periodType == PERIOD_WEEK) return startTs + 7 days - 1;
        (uint256 year, uint256 month, ) = _daysToDate(startTs / 1 days);
        uint256 nextStart;
        if (periodType == PERIOD_MONTH) {
            (uint256 y, uint256 m) = _addMonths(year, month, 1);
            nextStart = _timestampFromDate(y, m, 1);
            return nextStart - 1;
        }
        if (periodType == PERIOD_QUARTER) {
            (uint256 y2, uint256 m2) = _addMonths(year, month, 3);
            nextStart = _timestampFromDate(y2, m2, 1);
            return nextStart - 1;
        }
        nextStart = _timestampFromDate(year + 1, 1, 1);
        return nextStart - 1;
    }

    function _previousPeriodStart(uint256 currentStart, uint8 periodType) internal pure returns (uint256) {
        if (periodType == PERIOD_HOUR) return currentStart - 1 hours;
        if (periodType == PERIOD_DAY) return currentStart - 1 days;
        if (periodType == PERIOD_WEEK) return currentStart - 7 days;
        (uint256 year, uint256 month, ) = _daysToDate(currentStart / 1 days);
        if (periodType == PERIOD_MONTH) {
            (uint256 y, uint256 m) = _addMonths(year, month, -1);
            return _timestampFromDate(y, m, 1);
        }
        if (periodType == PERIOD_QUARTER) {
            (uint256 y2, uint256 m2) = _addMonths(year, month, -3);
            return _timestampFromDate(y2, m2, 1);
        }
        return _timestampFromDate(year - 1, 1, 1);
    }

    function _resolvePeriodRange(uint256 ts, uint8 periodType) internal pure returns (uint256 startTs, uint256 endTs) {
        if (periodType == PERIOD_HOUR) {
            startTs = (ts / 1 hours) * 1 hours;
            endTs = startTs + 1 hours - 1;
            return (startTs, endTs);
        }
        if (periodType == PERIOD_DAY) {
            startTs = (ts / 1 days) * 1 days;
            endTs = startTs + 1 days - 1;
            return (startTs, endTs);
        }
        uint256 daysSinceEpoch = ts / 1 days;
        if (periodType == PERIOD_WEEK) {
            uint256 mondayIndex = (daysSinceEpoch + 3) % 7;
            startTs = (daysSinceEpoch - mondayIndex) * 1 days;
            endTs = startTs + 7 days - 1;
            return (startTs, endTs);
        }
        (uint256 year, uint256 month, ) = _daysToDate(daysSinceEpoch);
        if (periodType == PERIOD_MONTH) {
            startTs = _timestampFromDate(year, month, 1);
            (uint256 y1, uint256 m1) = _addMonths(year, month, 1);
            endTs = _timestampFromDate(y1, m1, 1) - 1;
            return (startTs, endTs);
        }
        if (periodType == PERIOD_QUARTER) {
            uint256 quarterStartMonth = ((month - 1) / 3) * 3 + 1;
            startTs = _timestampFromDate(year, quarterStartMonth, 1);
            (uint256 y2, uint256 m2) = _addMonths(year, quarterStartMonth, 3);
            endTs = _timestampFromDate(y2, m2, 1) - 1;
            return (startTs, endTs);
        }
        startTs = _timestampFromDate(year, 1, 1);
        endTs = _timestampFromDate(year + 1, 1, 1) - 1;
    }

    function _timestampFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        return _daysFromDate(year, month, day) * 1 days;
    }

    function _addMonths(uint256 year, uint256 month, int256 offset) internal pure returns (uint256 ny, uint256 nm) {
        int256 ym = int256(year) * 12 + int256(month) - 1 + offset;
        require(ym >= 0, "date underflow");
        ny = uint256(ym / 12);
        nm = uint256(ym % 12) + 1;
    }

    function _daysFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256 _days) {
        require(year >= 1970, "year<1970");
        int256 _year = int256(year);
        int256 _month = int256(month);
        int256 _day = int256(day);
        int256 __days = _day
            - 32075
            + (1461 * (_year + 4800 + (_month - 14) / 12)) / 4
            + (367 * (_month - 2 - ((_month - 14) / 12) * 12)) / 12
            - (3 * ((_year + 4900 + (_month - 14) / 12) / 100)) / 4
            - 2440588;
        _days = uint256(__days);
    }

    function _daysToDate(uint256 _days) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 __days = int256(_days);
        int256 L = __days + 68569 + 2440588;
        int256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 _year = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * _year) / 4 + 31;
        int256 _month = (80 * L) / 2447;
        int256 _day = L - (2447 * _month) / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;
        year = uint256(_year);
        month = uint256(_month);
        day = uint256(_day);
    }
}
