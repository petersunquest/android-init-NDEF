// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CoNETIncomePeriodLib
 * @notice UTC period bucket math aligned with ValidatorNodeRewardIndexer / AdminStatsPeriodLib.
 *         Hour = epoch hour; week = Monday-start; month/year = calendar UTC.
 *         Used by GBDepinAirdrop paid-GB ledger and (planned) ValidatorDepositRedeem CL settle ledger.
 */
library CoNETIncomePeriodLib {
    uint8 internal constant PERIOD_HOUR = 0;
    uint8 internal constant PERIOD_DAY = 1;
    uint8 internal constant PERIOD_WEEK = 2;
    uint8 internal constant PERIOD_MONTH = 3;
    uint8 internal constant PERIOD_YEAR = 5;

    struct IncomePeriodSummary {
        uint256 cumulative;
        uint256 hour;
        uint256 day;
        uint256 week;
        uint256 month;
        uint256 year;
    }

    /// @dev Write {amount} into hour + coarse period buckets for block timestamp {ts}.
    function accumulate(
        mapping(uint256 => uint256) storage hourly,
        mapping(uint8 => mapping(uint256 => uint256)) storage period,
        uint256 ts,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        uint256 hourId = ts / 3600;
        hourly[hourId] += amount;

        uint256 hourAlignedTs = hourId * 3600;
        uint256 dayId = hourAlignedTs / 1 days;
        uint256 weekId = (dayId + 3) / 7;
        (uint256 y, uint256 m, ) = _daysToDate(dayId);
        uint256 monthId = y * 12 + (m - 1);

        period[PERIOD_DAY][dayId] += amount;
        period[PERIOD_WEEK][weekId] += amount;
        period[PERIOD_MONTH][monthId] += amount;
        period[PERIOD_YEAR][y] += amount;
    }

    /// @dev O(1) read of buckets containing {anchorTs} (0 = block.timestamp).
    function readSummary(
        mapping(uint256 => uint256) storage hourly,
        mapping(uint8 => mapping(uint256 => uint256)) storage period,
        uint256 cumulative,
        uint256 anchorTs
    ) internal view returns (IncomePeriodSummary memory s) {
        uint256 useAnchor = anchorTs == 0 ? block.timestamp : anchorTs;
        s.cumulative = cumulative;
        s.hour = hourly[_periodId(useAnchor, PERIOD_HOUR)];
        s.day = period[PERIOD_DAY][_periodId(useAnchor, PERIOD_DAY)];
        s.week = period[PERIOD_WEEK][_periodId(useAnchor, PERIOD_WEEK)];
        s.month = period[PERIOD_MONTH][_periodId(useAnchor, PERIOD_MONTH)];
        s.year = period[PERIOD_YEAR][_periodId(useAnchor, PERIOD_YEAR)];
    }

    function _periodId(uint256 ts, uint8 periodType) private pure returns (uint256) {
        if (periodType == PERIOD_HOUR) return ts / 3600;
        if (periodType == PERIOD_DAY) return ts / 1 days;
        if (periodType == PERIOD_WEEK) return (ts / 1 days + 3) / 7;
        (uint256 y, uint256 m, ) = _daysToDate(ts / 1 days);
        if (periodType == PERIOD_MONTH) return y * 12 + (m - 1);
        return y;
    }

    function _daysToDate(uint256 daysSinceEpoch) private pure returns (uint256 year, uint256 month, uint256 day) {
        int256 __days = int256(daysSinceEpoch);
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
