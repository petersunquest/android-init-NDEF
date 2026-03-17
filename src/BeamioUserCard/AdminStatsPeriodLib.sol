// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AdminStatsStorage.sol";

/**
 * @title AdminStatsPeriodLib
 * @notice 日/周/月/季/年周期聚合逻辑，与 Indexer StatsFacet 对齐
 */
library AdminStatsPeriodLib {
    uint256 internal constant MAX_HOURS = 24 * 366 * 5;
    uint8 internal constant PERIOD_HOUR = 0;
    uint8 internal constant PERIOD_DAY = 1;
    uint8 internal constant PERIOD_WEEK = 2;
    uint8 internal constant PERIOD_MONTH = 3;
    uint8 internal constant PERIOD_QUARTER = 4;
    uint8 internal constant PERIOD_YEAR = 5;
    uint256 internal constant MAX_PERIODS = 120;

    struct AggregatedStats {
        uint256 totalNftMinted;
        uint256 totalTokenMinted;
        uint256 totalTokenBurned;
        uint256 totalTransfers;
        uint256 totalTransferAmount;
        uint256 totalRedeemMint;
        uint256 totalUSDCMint;
        uint256 totalIssued;
        uint256 totalUpgraded;
    }

    struct PeriodReport {
        uint256 periodStart;
        uint256 periodEnd;
        AggregatedStats stats;
    }

    struct AdminPeriodReportsResult {
        PeriodReport[] reports;
        uint256 adminMintCounter;
    }

    /// @notice 全局累计统计：所有 admin 聚合，无分层
    struct GlobalStatsFullResult {
        uint256 cumulativeMint;
        uint256 cumulativeBurn;
        uint256 cumulativeTransfer;
        uint256 cumulativeTransferAmount;
        uint256 cumulativeRedeemMint;
        uint256 cumulativeUSDCMint;
        uint256 cumulativeIssued;
        uint256 cumulativeUpgraded;
        uint256 periodMint;
        uint256 periodBurn;
        uint256 periodTransfer;
        uint256 periodTransferAmount;
        uint256 periodRedeemMint;
        uint256 periodUSDCMint;
        uint256 periodIssued;
        uint256 periodUpgraded;
        uint256 adminCount;
    }

    /// @notice 完整返回：自己及下层 admin 的聚合统计 + 从上次 clear 起的计数 + 下层数组
    struct AdminStatsFullResult {
        uint256 cumulativeMint;
        uint256 cumulativeBurn;
        uint256 cumulativeTransfer;
        uint256 cumulativeTransferAmount;
        uint256 cumulativeRedeemMint;
        uint256 cumulativeUSDCMint;
        uint256 cumulativeIssued;
        uint256 cumulativeUpgraded;
        uint256 periodMint;
        uint256 periodBurn;
        uint256 periodTransfer;
        uint256 periodTransferAmount;
        uint256 periodRedeemMint;
        uint256 periodUSDCMint;
        uint256 periodIssued;
        uint256 periodUpgraded;
        uint256 mintCounterFromClear;
        uint256 burnCounterFromClear;
        uint256 transferCounterFromClear;
        uint256 transferAmountFromClear;
        uint256 redeemMintCounterFromClear;
        uint256 usdcMintCounterFromClear;
        address[] subordinates;
    }

    /// @notice 对多个 admin 聚合时间区间内的统计
    function aggregateBetweenForAdmins(
        AdminStatsStorage.Layout storage l,
        address[] memory admins,
        uint256 startTimestamp,
        uint256 endTimestamp
    ) internal view returns (AggregatedStats memory stats) {
        if (endTimestamp < startTimestamp) return stats;
        uint256 startHour = startTimestamp / 3600;
        uint256 endHour = endTimestamp / 3600;
        if (endHour < startHour) return stats;
        if (endHour - startHour > MAX_HOURS) return stats;
        for (uint256 a = 0; a < admins.length; a++) {
            for (uint256 i = startHour; i <= endHour; i++) {
                AdminStatsStorage.HourlyStats storage h = l.adminHourlyData[admins[a]][i];
                if (h.hasData) {
                    stats.totalNftMinted += h.nftMinted;
                    stats.totalTokenMinted += h.tokenMinted;
                    stats.totalTokenBurned += h.tokenBurned;
                    stats.totalTransfers += h.transferCount;
                    stats.totalTransferAmount += h.transferAmount;
                    stats.totalRedeemMint += h.redeemMintAmount;
                    stats.totalUSDCMint += h.usdcMintAmount;
                    stats.totalIssued += h.issuedCount;
                    stats.totalUpgraded += h.upgradedCount;
                }
            }
        }
    }

    function aggregateBetween(
        AdminStatsStorage.Layout storage l,
        address admin,
        uint256 startTimestamp,
        uint256 endTimestamp
    ) internal view returns (AggregatedStats memory stats) {
        if (endTimestamp < startTimestamp) return stats;
        uint256 startHour = startTimestamp / 3600;
        uint256 endHour = endTimestamp / 3600;
        if (endHour < startHour) return stats;
        if (endHour - startHour > MAX_HOURS) return stats;

        for (uint256 i = startHour; i <= endHour; i++) {
            AdminStatsStorage.HourlyStats storage h = l.adminHourlyData[admin][i];
            if (h.hasData) {
                stats.totalNftMinted += h.nftMinted;
                stats.totalTokenMinted += h.tokenMinted;
                stats.totalTokenBurned += h.tokenBurned;
                stats.totalTransfers += h.transferCount;
                stats.totalTransferAmount += h.transferAmount;
                stats.totalRedeemMint += h.redeemMintAmount;
                stats.totalUSDCMint += h.usdcMintAmount;
                stats.totalIssued += h.issuedCount;
                stats.totalUpgraded += h.upgradedCount;
            }
        }
    }

    /// @notice 获取 admin 及所有下层 admin 的完整统计（自己+下属的聚合）
    /// @param admins 包含 admin 及其所有 subordinate 的地址数组
    /// @param cumulativeStartTs 累计起点时间戳；0 表示 endTs - MAX_HOURS*3600
    function getAdminStatsFull(
        AdminStatsStorage.Layout storage l,
        address[] memory admins,
        uint8 periodType,
        uint256 anchorTs,
        uint256 cumulativeStartTs
    ) internal view returns (AdminStatsFullResult memory result) {
        require(_isValidPeriodType(periodType), "bad periodType");
        uint256 useAnchor = anchorTs == 0 ? block.timestamp : anchorTs;
        uint256 endTs = useAnchor;
        uint256 startCum = cumulativeStartTs == 0 ? (endTs >= MAX_HOURS * 3600 ? endTs - MAX_HOURS * 3600 : 0) : cumulativeStartTs;

        result.cumulativeMint = 0;
        result.cumulativeBurn = 0;
        result.cumulativeTransfer = 0;
        result.mintCounterFromClear = 0;
        result.burnCounterFromClear = 0;
        result.transferCounterFromClear = 0;
        result.transferAmountFromClear = 0;
        result.redeemMintCounterFromClear = 0;
        result.usdcMintCounterFromClear = 0;
        for (uint256 i = 0; i < admins.length; i++) {
            result.mintCounterFromClear += l.adminMintCounter[admins[i]];
            result.burnCounterFromClear += l.adminBurnCounter[admins[i]];
            result.transferCounterFromClear += l.adminTransferCounter[admins[i]];
            result.transferAmountFromClear += l.adminTransferAmountCounter[admins[i]];
            result.redeemMintCounterFromClear += l.adminRedeemMintCounter[admins[i]];
            result.usdcMintCounterFromClear += l.adminUSDCMintCounter[admins[i]];
        }
        AggregatedStats memory cum = aggregateBetweenForAdmins(l, admins, startCum, endTs);
        result.cumulativeMint = cum.totalTokenMinted;
        result.cumulativeBurn = cum.totalTokenBurned;
        result.cumulativeTransfer = cum.totalTransfers;
        result.cumulativeTransferAmount = cum.totalTransferAmount;
        result.cumulativeRedeemMint = cum.totalRedeemMint;
        result.cumulativeUSDCMint = cum.totalUSDCMint;
        result.cumulativeIssued = cum.totalIssued;
        result.cumulativeUpgraded = cum.totalUpgraded;

        uint256 periodStart = _periodStart(useAnchor, periodType);
        uint256 periodEnd = _periodEndFromStart(periodStart, periodType);
        AggregatedStats memory per = aggregateBetweenForAdmins(l, admins, periodStart, periodEnd);
        result.periodMint = per.totalTokenMinted;
        result.periodBurn = per.totalTokenBurned;
        result.periodTransfer = per.totalTransfers;
        result.periodTransferAmount = per.totalTransferAmount;
        result.periodRedeemMint = per.totalRedeemMint;
        result.periodUSDCMint = per.totalUSDCMint;
        result.periodIssued = per.totalIssued;
        result.periodUpgraded = per.totalUpgraded;

        result.subordinates = new address[](admins.length > 1 ? admins.length - 1 : 0);
        for (uint256 j = 1; j < admins.length; j++) result.subordinates[j - 1] = admins[j];
    }

    /// @notice 全局累计统计（所有 admin 聚合，无分层）
    function getGlobalStatsFull(
        AdminStatsStorage.Layout storage l,
        address[] memory admins,
        uint8 periodType,
        uint256 anchorTs,
        uint256 cumulativeStartTs
    ) internal view returns (GlobalStatsFullResult memory result) {
        require(_isValidPeriodType(periodType), "bad periodType");
        uint256 useAnchor = anchorTs == 0 ? block.timestamp : anchorTs;
        uint256 endTs = useAnchor;
        uint256 startCum = cumulativeStartTs == 0 ? (endTs >= MAX_HOURS * 3600 ? endTs - MAX_HOURS * 3600 : 0) : cumulativeStartTs;

        AggregatedStats memory cum = aggregateBetweenForAdmins(l, admins, startCum, endTs);
        result.cumulativeMint = cum.totalTokenMinted;
        result.cumulativeBurn = cum.totalTokenBurned;
        result.cumulativeTransfer = cum.totalTransfers;
        result.cumulativeTransferAmount = cum.totalTransferAmount;
        result.cumulativeRedeemMint = cum.totalRedeemMint;
        result.cumulativeUSDCMint = cum.totalUSDCMint;
        result.cumulativeIssued = cum.totalIssued;
        result.cumulativeUpgraded = cum.totalUpgraded;

        uint256 periodStart = _periodStart(useAnchor, periodType);
        uint256 periodEnd = _periodEndFromStart(periodStart, periodType);
        AggregatedStats memory per = aggregateBetweenForAdmins(l, admins, periodStart, periodEnd);
        result.periodMint = per.totalTokenMinted;
        result.periodBurn = per.totalTokenBurned;
        result.periodTransfer = per.totalTransfers;
        result.periodTransferAmount = per.totalTransferAmount;
        result.periodRedeemMint = per.totalRedeemMint;
        result.periodUSDCMint = per.totalUSDCMint;
        result.periodIssued = per.totalIssued;
        result.periodUpgraded = per.totalUpgraded;

        result.adminCount = admins.length;
    }

    function getPeriodReports(
        AdminStatsStorage.Layout storage l,
        address admin,
        uint8 periodType,
        uint256 periods,
        uint256 anchorTs
    ) internal view returns (AdminPeriodReportsResult memory result) {
        require(_isValidPeriodType(periodType), "bad periodType");
        require(periods > 0 && periods <= MAX_PERIODS, "bad periods");

        uint256 useAnchor = anchorTs == 0 ? block.timestamp : anchorTs;
        result.reports = new PeriodReport[](periods);
        result.adminMintCounter = l.adminMintCounter[admin];

        uint256 periodStart = _periodStart(useAnchor, periodType);
        for (uint256 i = 0; i < periods; i++) {
            uint256 periodEnd = _periodEndFromStart(periodStart, periodType);
            result.reports[i].periodStart = periodStart;
            result.reports[i].periodEnd = periodEnd;
            result.reports[i].stats = aggregateBetween(l, admin, periodStart, periodEnd);
            periodStart = _previousPeriodStart(periodStart, periodType);
        }
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

    function _periodStart(uint256 ts, uint8 periodType) internal pure returns (uint256) {
        if (periodType == PERIOD_HOUR) return (ts / 3600) * 3600;
        if (periodType == PERIOD_DAY) return (ts / 1 days) * 1 days;
        uint256 daysSinceEpoch = ts / 1 days;
        if (periodType == PERIOD_WEEK) {
            uint256 mondayIndex = (daysSinceEpoch + 3) % 7;
            return (daysSinceEpoch - mondayIndex) * 1 days;
        }
        (uint256 year, uint256 month, ) = _daysToDate(daysSinceEpoch);
        if (periodType == PERIOD_MONTH) return _timestampFromDate(year, month, 1);
        if (periodType == PERIOD_QUARTER) {
            uint256 quarterStartMonth = ((month - 1) / 3) * 3 + 1;
            return _timestampFromDate(year, quarterStartMonth, 1);
        }
        return _timestampFromDate(year, 1, 1);
    }

    function _periodEndFromStart(uint256 startTs, uint8 periodType) internal pure returns (uint256) {
        if (periodType == PERIOD_HOUR) return startTs + 3600 - 1;
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
        if (periodType == PERIOD_HOUR) return currentStart - 3600;
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
