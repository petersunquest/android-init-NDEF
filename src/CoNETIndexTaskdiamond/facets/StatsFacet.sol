// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibStatsStorage} from "../libraries/LibStatsStorage.sol";
import {LibAdminStorage} from "../libraries/LibAdminStorage.sol";

contract StatsFacet {
    // ✅ 只保留一个 MAX_HOURS() getter（避免 CatalogFacet 冲突）
    // 支持商业年报：1 年约 8,784 小时（闰年），这里给到 5 年窗口余量
    uint256 public constant MAX_HOURS = 24 * 366 * 5;
    uint8 public constant PERIOD_DAY = 1;
    uint8 public constant PERIOD_WEEK = 2;
    uint8 public constant PERIOD_MONTH = 3;
    uint8 public constant PERIOD_QUARTER = 4;
    uint8 public constant PERIOD_YEAR = 5;
    uint256 public constant MAX_PERIODS = 120;

    struct AggregatedStats {
        uint256 totalNftMinted;
        uint256 totalTokenMinted;
        uint256 totalTokenBurned;
        uint256 totalTransfers;
    }

    struct PeriodReport {
        uint256 periodStart;
        uint256 periodEnd;
        AggregatedStats stats;
    }

    /// @notice admin 每小时查询的完整返回：原子小时数据 + 从开始起的累计 + 从清零起的 mintCounter
    struct AdminHourlyStatsResult {
        LibStatsStorage.HourlyStats hourly;
        uint256 cumulativeTokenMintedFromBegin;
        uint256 cumulativeTokenBurnedFromBegin;
        uint256 adminMintCounterByCard;
    }

    /// @notice admin 聚合/周期查询的完整返回：聚合统计 + 从开始起的累计 + 从清零起的 mintCounter
    struct AdminAggregatedResult {
        AggregatedStats stats;
        uint256 cumulativeTokenMintedFromBegin;
        uint256 cumulativeTokenBurnedFromBegin;
        uint256 adminMintCounterByCard;
    }

    /// @notice admin 商业周期报表的完整返回：周期报表 + 从开始起的累计 + 从清零起的 mintCounter
    struct AdminPeriodReportsResult {
        PeriodReport[] reports;
        uint256 cumulativeTokenMintedFromBegin;
        uint256 cumulativeTokenBurnedFromBegin;
        uint256 adminMintCounterByCard;
    }

    function _enforceIsOwnerOrAdmin() internal view {
        if (msg.sender == LibDiamond.contractOwner()) return;
        require(LibAdminStorage.layout().isAdmin[msg.sender], "not admin");
    }

    event StatsUpdated(uint256 indexed hourIndex, address indexed card, address indexed user);

    /**
     * @notice 实时写入（按 block.timestamp）
     */
    function recordDetailedActivity(
        address card,
        address user,
        uint256 nftCount,
        uint256 mintAmount,
        uint256 burnAmount,
        uint256 transfers
    ) external {
        _enforceIsOwnerOrAdmin();
        _recordDetailedActivityAt(block.timestamp, card, user, nftCount, mintAmount, burnAmount, transfers);
    }

    /**
     * @notice ✅ 明确对外的“按指定 ts 写入”接口（给 TaskFacet/ActionFacet/API 用）
     * @dev 仍只允许 diamond owner 调用
     */
    function recordDetailedActivityAt(
        uint256 ts,
        address card,
        address user,
        uint256 nftCount,
        uint256 mintAmount,
        uint256 burnAmount,
        uint256 transfers
    ) external {
        _enforceIsOwnerOrAdmin();
        _recordDetailedActivityAt(ts, card, user, nftCount, mintAmount, burnAmount, transfers);
    }

    /**
     * @notice 按 admin 记录 token #0 (points) 的 mint/burn，用于小时原子统计
     * @dev 可由 diamond owner/admin 调用，或经 syncTokenAction 传入 operator 时由 ActionFacet 内部更新
     */
    function recordAdminToken0ActivityAt(
        uint256 ts,
        address admin,
        uint256 mintAmount,
        uint256 burnAmount
    ) external {
        _enforceIsOwnerOrAdmin();
        if (admin == address(0)) return;
        if (mintAmount == 0 && burnAmount == 0) return;
        LibStatsStorage.Layout storage s = LibStatsStorage.layout();
        uint256 hourIndex = ts / 3600;
        _updateHourlyStats(s.adminHourlyData[admin][hourIndex], 0, mintAmount, burnAmount, 0);
    }

    function _recordDetailedActivityAt(
        uint256 ts,
        address card,
        address user,
        uint256 nftCount,
        uint256 mintAmount,
        uint256 burnAmount,
        uint256 transfers
    ) internal {
        LibStatsStorage.Layout storage s = LibStatsStorage.layout();
        uint256 hourIndex = ts / 3600;

        _updateHourlyStats(s.hourlyData[hourIndex], nftCount, mintAmount, burnAmount, transfers);
        _updateHourlyStats(s.cardHourlyData[card][hourIndex], nftCount, mintAmount, burnAmount, transfers);
        _updateHourlyStats(s.userHourlyData[user][hourIndex], nftCount, mintAmount, burnAmount, transfers);

        emit StatsUpdated(hourIndex, card, user);
    }

    function _updateHourlyStats(
        LibStatsStorage.HourlyStats storage st,
        uint256 nft,
        uint256 mint,
        uint256 burn,
        uint256 trans
    ) internal {
        if (!st.hasData) st.hasData = true;
        st.nftMinted += nft;
        st.tokenMinted += mint;
        st.tokenBurned += burn;
        st.transferCount += trans;
    }

    // --- view: expose raw data mappings via helpers ---
    function getHourlyData(uint256 hourIndex) external view returns (LibStatsStorage.HourlyStats memory) {
        return LibStatsStorage.layout().hourlyData[hourIndex];
    }

    function getCardHourlyData(address card, uint256 hourIndex) external view returns (LibStatsStorage.HourlyStats memory) {
        return LibStatsStorage.layout().cardHourlyData[card][hourIndex];
    }

    function getUserHourlyData(address user, uint256 hourIndex) external view returns (LibStatsStorage.HourlyStats memory) {
        return LibStatsStorage.layout().userHourlyData[user][hourIndex];
    }

    function getAggregatedStats(
        uint8 mode,
        address account,
        uint256 startTimestamp,
        uint256 endTimestamp
    ) public view returns (AggregatedStats memory stats) {
        if (endTimestamp < startTimestamp) return stats;
        return _aggregateBetween(mode, account, startTimestamp, endTimestamp);
    }

    function getStatsSince(
        uint8 mode,
        address account,
        uint256 startTimestamp
    ) external view returns (AggregatedStats memory) {
        return getAggregatedStats(mode, account, startTimestamp, block.timestamp);
    }

    /**
     * @notice 按商业报表周期返回最近 N 个周期统计（从 anchor 所在周期向前）
     * @param mode 0=全局, 1=按 card, 2=按 user, 3=按 admin（token #0 mint/burn）
     * @param account mode=1/2/3 时对应地址，其它模式可传 address(0)
     * @param periodType 1=日,2=周,3=月,4=季度,5=年
     * @param periods 需要返回的周期数量（最大 MAX_PERIODS）
     * @param anchorTs 参考时间戳，传 0 时使用 block.timestamp
     */
    function getBusinessPeriodReports(
        uint8 mode,
        address account,
        uint8 periodType,
        uint256 periods,
        uint256 anchorTs
    ) public view returns (PeriodReport[] memory reports) {
        require(_isValidPeriodType(periodType), "bad periodType");
        require(periods > 0 && periods <= MAX_PERIODS, "bad periods");

        uint256 useAnchor = anchorTs == 0 ? block.timestamp : anchorTs;
        reports = new PeriodReport[](periods);

        uint256 periodStart = _periodStart(useAnchor, periodType);
        for (uint256 i = 0; i < periods; i++) {
            uint256 periodEnd = _periodEndFromStart(periodStart, periodType);
            reports[i].periodStart = periodStart;
            reports[i].periodEnd = periodEnd;
            reports[i].stats = _aggregateBetween(mode, account, periodStart, periodEnd);
            periodStart = _previousPeriodStart(periodStart, periodType);
        }
    }

    /**
     * @notice 返回指定小时的“原子统计”
     * @param mode 0=全局, 1=按 card, 2=按 user, 3=按 admin（token #0 mint/burn）
     */
    function getAtomicHourStats(uint8 mode, address account, uint256 hourIndex)
        external
        view
        returns (LibStatsStorage.HourlyStats memory)
    {
        LibStatsStorage.Layout storage s = LibStatsStorage.layout();
        if (mode == 0) return s.hourlyData[hourIndex];
        if (mode == 1) return s.cardHourlyData[account][hourIndex];
        if (mode == 2) return s.userHourlyData[account][hourIndex];
        require(mode == 3, "bad mode");
        return s.adminHourlyData[account][hourIndex];
    }

    /// @notice 按 admin 返回指定小时的 token #0 mint/burn 原子统计
    function getAdminHourlyData(address admin, uint256 hourIndex)
        external
        view
        returns (LibStatsStorage.HourlyStats memory)
    {
        return LibStatsStorage.layout().adminHourlyData[admin][hourIndex];
    }

    /// @notice 按 admin 返回指定小时的完整统计：原子数据 + 从开始起的累计 + 从清零起的 adminMintCounterByCard
    /// @param cumulativeStartHour 累计起点 hourIndex；type(uint256).max 表示自动取 max(0, hourIndex - MAX_HOURS + 1)
    function getAdminHourlyDataFull(
        address admin,
        address card,
        uint256 hourIndex,
        uint256 cumulativeStartHour
    ) external view returns (AdminHourlyStatsResult memory result) {
        LibStatsStorage.Layout storage s = LibStatsStorage.layout();
        result.hourly = s.adminHourlyData[admin][hourIndex];
        result.adminMintCounterByCard = card != address(0) ? s.adminMintCounterByCard[card][admin] : 0;
        uint256 startH = cumulativeStartHour == type(uint256).max ? (hourIndex >= MAX_HOURS ? hourIndex - MAX_HOURS + 1 : 0) : cumulativeStartHour;
        if (startH <= hourIndex && hourIndex - startH < MAX_HOURS) {
            for (uint256 i = startH; i <= hourIndex; i++) {
                LibStatsStorage.HourlyStats storage h = s.adminHourlyData[admin][i];
                if (h.hasData) {
                    result.cumulativeTokenMintedFromBegin += h.tokenMinted;
                    result.cumulativeTokenBurnedFromBegin += h.tokenBurned;
                }
            }
        }
    }

    /// @notice 按 admin 返回指定小时的原子统计 + adminMintCounterByCard；card 为 address(0) 时 mintCounter 返回 0
    /// @dev 如需累计信息请用 getAdminHourlyDataFull
    function getAdminHourlyDataWithMintCounter(address admin, address card, uint256 hourIndex)
        external
        view
        returns (LibStatsStorage.HourlyStats memory hourly, uint256 mintCounter)
    {
        LibStatsStorage.Layout storage s = LibStatsStorage.layout();
        hourly = s.adminHourlyData[admin][hourIndex];
        mintCounter = card != address(0) ? s.adminMintCounterByCard[card][admin] : 0;
    }

    /// @notice 按 admin 返回时间区间聚合统计 + 从开始起的累计 + adminMintCounterByCard
    /// @param cumulativeStartTs 累计起点时间戳；0 时使用 endTimestamp - MAX_HOURS*3600
    function getAdminAggregatedStatsWithMintCounter(
        address admin,
        address card,
        uint256 startTimestamp,
        uint256 endTimestamp,
        uint256 cumulativeStartTs
    ) external view returns (AdminAggregatedResult memory result) {
        result.stats = getAggregatedStats(3, admin, startTimestamp, endTimestamp);
        result.adminMintCounterByCard = card != address(0) ? LibStatsStorage.layout().adminMintCounterByCard[card][admin] : 0;
        uint256 endHour = endTimestamp / 3600;
        uint256 startHour = cumulativeStartTs == 0 ? (endHour >= MAX_HOURS ? endHour - MAX_HOURS + 1 : 0) : cumulativeStartTs / 3600;
        if (startHour <= endHour && endHour - startHour < MAX_HOURS) {
            LibStatsStorage.Layout storage s = LibStatsStorage.layout();
            for (uint256 i = startHour; i <= endHour; i++) {
                LibStatsStorage.HourlyStats storage h = s.adminHourlyData[admin][i];
                if (h.hasData) {
                    result.cumulativeTokenMintedFromBegin += h.tokenMinted;
                    result.cumulativeTokenBurnedFromBegin += h.tokenBurned;
                }
            }
        }
    }

    /// @notice 按 admin 返回商业周期报表 + 从开始起的累计 + adminMintCounterByCard
    /// @param cumulativeStartTs 累计起点时间戳；0 时使用 anchorTs - MAX_HOURS*3600
    function getAdminBusinessPeriodReportsWithMintCounter(
        address admin,
        address card,
        uint8 periodType,
        uint256 periods,
        uint256 anchorTs,
        uint256 cumulativeStartTs
    ) external view returns (AdminPeriodReportsResult memory result) {
        result.reports = getBusinessPeriodReports(3, admin, periodType, periods, anchorTs);
        result.adminMintCounterByCard = card != address(0) ? LibStatsStorage.layout().adminMintCounterByCard[card][admin] : 0;
        uint256 useAnchor = anchorTs == 0 ? block.timestamp : anchorTs;
        uint256 endHour = useAnchor / 3600;
        uint256 startHour = cumulativeStartTs == 0 ? (endHour >= MAX_HOURS ? endHour - MAX_HOURS + 1 : 0) : cumulativeStartTs / 3600;
        if (startHour <= endHour && endHour - startHour < MAX_HOURS) {
            LibStatsStorage.Layout storage s = LibStatsStorage.layout();
            for (uint256 i = startHour; i <= endHour; i++) {
                LibStatsStorage.HourlyStats storage h = s.adminHourlyData[admin][i];
                if (h.hasData) {
                    result.cumulativeTokenMintedFromBegin += h.tokenMinted;
                    result.cumulativeTokenBurnedFromBegin += h.tokenBurned;
                }
            }
        }
    }

    /// @notice 按 (card, admin) 返回 cumulative mint token 0 计数；查询 admin 时连同其他信息一起回送
    function getAdminMintCounter(address card, address admin) external view returns (uint256) {
        return LibStatsStorage.layout().adminMintCounterByCard[card][admin];
    }

    /// @notice parent admin 清零 subordinate 的 mint 计数；仅 diamond owner/admin 可调用，调用前需校验 card.adminParent(subordinate)==authorizer
    function clearAdminMintCounterForSubordinate(address card, address subordinate) external {
        _enforceIsOwnerOrAdmin();
        if (card == address(0) || subordinate == address(0)) return;
        LibStatsStorage.layout().adminMintCounterByCard[card][subordinate] = 0;
    }

    function _aggregateBetween(
        uint8 mode,
        address account,
        uint256 startTimestamp,
        uint256 endTimestamp
    ) internal view returns (AggregatedStats memory stats) {
        if (endTimestamp < startTimestamp) return stats;

        uint256 startHour = startTimestamp / 3600;
        uint256 endHour = endTimestamp / 3600;
        if (endHour < startHour) return stats;
        require(endHour - startHour <= MAX_HOURS, "range too large");

        LibStatsStorage.Layout storage s = LibStatsStorage.layout();
        for (uint256 i = startHour; i <= endHour; i++) {
            LibStatsStorage.HourlyStats storage h;
            if (mode == 0) h = s.hourlyData[i];
            else if (mode == 1) h = s.cardHourlyData[account][i];
            else if (mode == 2) h = s.userHourlyData[account][i];
            else {
                require(mode == 3, "bad mode");
                h = s.adminHourlyData[account][i];
            }

            if (h.hasData) {
                stats.totalNftMinted += h.nftMinted;
                stats.totalTokenMinted += h.tokenMinted;
                stats.totalTokenBurned += h.tokenBurned;
                stats.totalTransfers += h.transferCount;
            }
        }
    }

    function _isValidPeriodType(uint8 periodType) internal pure returns (bool) {
        return
            periodType == PERIOD_DAY ||
            periodType == PERIOD_WEEK ||
            periodType == PERIOD_MONTH ||
            periodType == PERIOD_QUARTER ||
            periodType == PERIOD_YEAR;
    }

    function _periodStart(uint256 ts, uint8 periodType) internal pure returns (uint256) {
        if (periodType == PERIOD_DAY) {
            return (ts / 1 days) * 1 days;
        }

        uint256 daysSinceEpoch = ts / 1 days;
        if (periodType == PERIOD_WEEK) {
            // 周起点按 UTC 周一 00:00 对齐
            uint256 mondayIndex = (daysSinceEpoch + 3) % 7;
            return (daysSinceEpoch - mondayIndex) * 1 days;
        }

        (uint256 year, uint256 month, ) = _daysToDate(daysSinceEpoch);
        if (periodType == PERIOD_MONTH) {
            return _timestampFromDate(year, month, 1);
        }
        if (periodType == PERIOD_QUARTER) {
            uint256 quarterStartMonth = ((month - 1) / 3) * 3 + 1;
            return _timestampFromDate(year, quarterStartMonth, 1);
        }
        // PERIOD_YEAR
        return _timestampFromDate(year, 1, 1);
    }

    function _periodEndFromStart(uint256 startTs, uint8 periodType) internal pure returns (uint256) {
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
        // PERIOD_YEAR
        nextStart = _timestampFromDate(year + 1, 1, 1);
        return nextStart - 1;
    }

    function _previousPeriodStart(uint256 currentStart, uint8 periodType) internal pure returns (uint256) {
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
        // PERIOD_YEAR
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

    // Date conversion algorithms adapted from BokkyPooBah's DateTime Library (MIT)
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
