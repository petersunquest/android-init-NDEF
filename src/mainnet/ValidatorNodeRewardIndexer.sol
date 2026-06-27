// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Reverse lookup into ValidatorDepositRedeem: a DePIN node wallet -> its current beneficiary (1:1).
interface IValidatorDepositRedeemBeneficiary {
    function getBeneficiaryByNodeWallet(address nodeWallet) external view returns (address);
}

/**
 * @title ValidatorNodeRewardIndexer
 * @notice Hourly atomic CNET reward ledger for CoNET DePIN validator nodes — per NODE and per BENEFICIARY —
 *         with day / week / month / quarter / year period statistics (BeamioIndexerDiamond / AdminStatsPeriodLib
 *         style). Kept as a standalone companion to {ValidatorDepositRedeem} so the core contract stays within
 *         the EVM contract size limit (EIP-170).
 *
 * @dev WHY OFF-CHAIN MEASURED / RELAYER FED:
 *      Validator CNET rewards have two physical sources that the chain cannot self-attribute per node:
 *        1. Execution-layer rewards (priority fees + MEV) are paid straight to the validator's `fee_recipient`
 *           (the hot-updated beneficiary wallet) — they never touch this contract.
 *        2. Consensus-layer skim returns to ValidatorDepositRedeem's 0x01 `withdrawal_credentials` WITHOUT any
 *           per-pubkey memo, so an incoming native transfer cannot be mapped to a node on-chain.
 *      Therefore the owning validator node / beacon listener measures each node's reward per UTC hour off-chain
 *      (beacon balance deltas + fee_recipient receipts) and writes it here. This ledger MOVES NO FUNDS; it is a
 *      display source for dashboards (per-node income curve + beneficiary totals).
 *
 *      Reward "follows the node": the per-beneficiary bucket for a given (node, hour) is attributed to whoever
 *      the beneficiary was when that hour was first reported, recorded in {hourBeneficiary} so later corrections
 *      stay consistent even after a node transfer.
 */
contract ValidatorNodeRewardIndexer {
    // ---- Period types (aligned with AdminStatsPeriodLib) -----------------------------------------------
    uint8 public constant PERIOD_HOUR = 0;
    uint8 public constant PERIOD_DAY = 1;
    uint8 public constant PERIOD_WEEK = 2;
    uint8 public constant PERIOD_MONTH = 3;
    uint8 public constant PERIOD_QUARTER = 4;
    uint8 public constant PERIOD_YEAR = 5;
    /// @dev Max hours scannable in a single aggregation (~5 years) to bound view gas.
    uint256 public constant MAX_HOURS = 24 * 366 * 5;
    /// @dev Max number of period reports per query.
    uint256 public constant MAX_PERIODS = 120;

    // ---- Admin (trusted relayer / Settle wallet) -------------------------------------------------------
    mapping(address => bool) public admins;
    /// @notice The ValidatorDepositRedeem contract used to resolve a node wallet's current beneficiary.
    IValidatorDepositRedeemBeneficiary public redeem;

    // ---- Hourly ledger ---------------------------------------------------------------------------------
    /// @notice node wallet => hourId (unix/3600) => CNET reward earned in that hour (18 decimals, absolute).
    mapping(address => mapping(uint256 => uint256)) public nodeHourlyReward;
    /// @notice beneficiary => hourId => aggregated CNET reward across the beneficiary's nodes in that hour.
    mapping(address => mapping(uint256 => uint256)) public beneficiaryHourlyReward;
    /// @notice node wallet => hourId => the beneficiary credited for that hour (set on first report; stable).
    mapping(address => mapping(uint256 => address)) public hourBeneficiary;

    // ---- Cumulative + bounds ---------------------------------------------------------------------------
    mapping(address => uint256) public nodeCumulativeReward;
    mapping(address => uint256) public beneficiaryCumulativeReward;
    uint256 public totalCumulativeReward;
    mapping(address => uint64) public nodeFirstHour;
    mapping(address => uint64) public nodeLastHour;
    mapping(address => uint64) public beneficiaryFirstHour;
    mapping(address => uint64) public beneficiaryLastHour;

    struct PeriodReport {
        uint256 periodStart; // inclusive unix start of the period
        uint256 periodEnd;   // inclusive unix end of the period
        uint256 reward;      // CNET reward summed over the period (18 decimals)
    }

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event RedeemConfigured(address indexed redeem);
    /// @notice An hour bucket for a node was (re)set; {beneficiary} is the credited beneficiary for that hour.
    event NodeRewardHourSet(
        address indexed nodeWallet,
        address indexed beneficiary,
        uint256 indexed hourId,
        uint256 reward
    );

    modifier onlyAdmin() {
        require(admins[msg.sender], "RewardIndexer: not admin");
        _;
    }

    constructor(address initialAdmin, address redeem_) {
        address admin = initialAdmin == address(0) ? msg.sender : initialAdmin;
        admins[admin] = true;
        emit AdminAdded(admin);
        if (redeem_ != address(0)) {
            redeem = IValidatorDepositRedeemBeneficiary(redeem_);
            emit RedeemConfigured(redeem_);
        }
    }

    function addAdmin(address account) external onlyAdmin {
        require(account != address(0), "RewardIndexer: zero");
        admins[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyAdmin {
        require(account != msg.sender, "RewardIndexer: self");
        admins[account] = false;
        emit AdminRemoved(account);
    }

    function setRedeem(address redeem_) external onlyAdmin {
        redeem = IValidatorDepositRedeemBeneficiary(redeem_);
        emit RedeemConfigured(redeem_);
    }

    /**
     * @notice Atomic hourly reward report (set-absolute per hour bucket; idempotent / crash-safe).
     * @dev The relayer may re-send the same (node, hour) with a corrected absolute value; the per-node and
     *      per-beneficiary cumulative + period totals are adjusted by the signed delta. The credited beneficiary
     *      for a (node, hour) is fixed on first report (resolved from {redeem}); re-reports keep that same
     *      beneficiary so an intervening node transfer never re-attributes already-credited hours.
     * @param nodeWallets DePIN node operator wallets.
     * @param hourIds UTC hour ids (unix timestamp / 3600), parallel to {nodeWallets}.
     * @param hourlyRewards Absolute CNET reward earned by the node in that hour (18 decimals), parallel.
     */
    function reportNodeRewardHourly(
        address[] calldata nodeWallets,
        uint256[] calldata hourIds,
        uint256[] calldata hourlyRewards
    ) external onlyAdmin {
        uint256 n = nodeWallets.length;
        require(n > 0, "RewardIndexer: empty");
        require(hourIds.length == n && hourlyRewards.length == n, "RewardIndexer: length mismatch");
        for (uint256 i = 0; i < n; i++) {
            _setNodeRewardHour(nodeWallets[i], hourIds[i], hourlyRewards[i]);
        }
    }

    function _setNodeRewardHour(address nodeWallet, uint256 hourId, uint256 newReward) internal {
        require(nodeWallet != address(0), "RewardIndexer: zero node");
        uint256 old = nodeHourlyReward[nodeWallet][hourId];
        if (newReward == old) return;

        // Resolve / pin the beneficiary credited for this (node, hour).
        address ben = hourBeneficiary[nodeWallet][hourId];
        if (ben == address(0)) {
            if (address(redeem) != address(0)) {
                ben = redeem.getBeneficiaryByNodeWallet(nodeWallet);
            }
            hourBeneficiary[nodeWallet][hourId] = ben; // may stay address(0) if node not yet bound
        }

        // Apply node bucket + cumulative via signed delta.
        nodeHourlyReward[nodeWallet][hourId] = newReward;
        if (newReward > old) {
            uint256 d = newReward - old;
            nodeCumulativeReward[nodeWallet] += d;
            totalCumulativeReward += d;
            if (ben != address(0)) {
                beneficiaryHourlyReward[ben][hourId] += d;
                beneficiaryCumulativeReward[ben] += d;
            }
        } else {
            uint256 d2 = old - newReward;
            nodeCumulativeReward[nodeWallet] -= d2;
            totalCumulativeReward -= d2;
            if (ben != address(0)) {
                beneficiaryHourlyReward[ben][hourId] -= d2;
                beneficiaryCumulativeReward[ben] -= d2;
            }
        }

        // Track first/last reported hour bounds (only widen).
        uint64 h64 = uint64(hourId);
        if (nodeFirstHour[nodeWallet] == 0 || h64 < nodeFirstHour[nodeWallet]) nodeFirstHour[nodeWallet] = h64;
        if (h64 > nodeLastHour[nodeWallet]) nodeLastHour[nodeWallet] = h64;
        if (ben != address(0)) {
            if (beneficiaryFirstHour[ben] == 0 || h64 < beneficiaryFirstHour[ben]) beneficiaryFirstHour[ben] = h64;
            if (h64 > beneficiaryLastHour[ben]) beneficiaryLastHour[ben] = h64;
        }

        emit NodeRewardHourSet(nodeWallet, ben, hourId, newReward);
    }

    // ---- Range / period views --------------------------------------------------------------------------

    /// @notice Sum a node's CNET reward over [startTs, endTs] (inclusive, hour-aligned scan).
    function getNodeRewardBetween(address nodeWallet, uint256 startTs, uint256 endTs)
        external
        view
        returns (uint256 reward)
    {
        return _aggregateNodeBetween(nodeWallet, startTs, endTs);
    }

    /// @notice Sum a beneficiary's CNET reward over [startTs, endTs] (inclusive, hour-aligned scan).
    function getBeneficiaryRewardBetween(address beneficiary, uint256 startTs, uint256 endTs)
        external
        view
        returns (uint256 reward)
    {
        return _aggregateBeneficiaryBetween(beneficiary, startTs, endTs);
    }

    /// @notice {periods} most-recent period reports for a NODE (newest first), each summed from hourly buckets.
    function getNodePeriodReports(address nodeWallet, uint8 periodType, uint256 periods, uint256 anchorTs)
        external
        view
        returns (PeriodReport[] memory reports)
    {
        return _periodReports(nodeWallet, false, periodType, periods, anchorTs);
    }

    /// @notice {periods} most-recent period reports for a BENEFICIARY (newest first).
    function getBeneficiaryPeriodReports(address beneficiary, uint8 periodType, uint256 periods, uint256 anchorTs)
        external
        view
        returns (PeriodReport[] memory reports)
    {
        return _periodReports(beneficiary, true, periodType, periods, anchorTs);
    }

    /// @notice One-shot summary for a node: cumulative + current hour/day/week/month/year totals.
    function getNodeRewardSummary(address nodeWallet, uint256 anchorTs)
        external
        view
        returns (
            uint256 cumulative,
            uint256 hour,
            uint256 day,
            uint256 week,
            uint256 month,
            uint256 year
        )
    {
        (cumulative, hour, day, week, month, year) = _rewardSummary(nodeWallet, false, anchorTs);
    }

    /// @notice One-shot summary for a beneficiary: cumulative + current hour/day/week/month/year totals.
    function getBeneficiaryRewardSummary(address beneficiary, uint256 anchorTs)
        external
        view
        returns (
            uint256 cumulative,
            uint256 hour,
            uint256 day,
            uint256 week,
            uint256 month,
            uint256 year
        )
    {
        (cumulative, hour, day, week, month, year) = _rewardSummary(beneficiary, true, anchorTs);
    }

    function _rewardSummary(address subject, bool isBeneficiary, uint256 anchorTs)
        internal
        view
        returns (uint256 cumulative, uint256 hour, uint256 day, uint256 week, uint256 month, uint256 year)
    {
        uint256 useAnchor = anchorTs == 0 ? block.timestamp : anchorTs;
        cumulative = isBeneficiary ? beneficiaryCumulativeReward[subject] : nodeCumulativeReward[subject];
        hour = _aggregatePeriod(subject, isBeneficiary, useAnchor, PERIOD_HOUR);
        day = _aggregatePeriod(subject, isBeneficiary, useAnchor, PERIOD_DAY);
        week = _aggregatePeriod(subject, isBeneficiary, useAnchor, PERIOD_WEEK);
        month = _aggregatePeriod(subject, isBeneficiary, useAnchor, PERIOD_MONTH);
        year = _aggregatePeriod(subject, isBeneficiary, useAnchor, PERIOD_YEAR);
    }

    function _aggregatePeriod(address subject, bool isBeneficiary, uint256 anchorTs, uint8 periodType)
        internal
        view
        returns (uint256)
    {
        uint256 start = _periodStart(anchorTs, periodType);
        uint256 end = _periodEndFromStart(start, periodType);
        return isBeneficiary
            ? _aggregateBeneficiaryBetween(subject, start, end)
            : _aggregateNodeBetween(subject, start, end);
    }

    function _periodReports(
        address subject,
        bool isBeneficiary,
        uint8 periodType,
        uint256 periods,
        uint256 anchorTs
    ) internal view returns (PeriodReport[] memory reports) {
        require(_isValidPeriodType(periodType), "RewardIndexer: bad period");
        require(periods > 0 && periods <= MAX_PERIODS, "RewardIndexer: bad periods");
        uint256 useAnchor = anchorTs == 0 ? block.timestamp : anchorTs;
        reports = new PeriodReport[](periods);
        uint256 periodStart = _periodStart(useAnchor, periodType);
        for (uint256 i = 0; i < periods; i++) {
            uint256 periodEnd = _periodEndFromStart(periodStart, periodType);
            reports[i].periodStart = periodStart;
            reports[i].periodEnd = periodEnd;
            reports[i].reward = isBeneficiary
                ? _aggregateBeneficiaryBetween(subject, periodStart, periodEnd)
                : _aggregateNodeBetween(subject, periodStart, periodEnd);
            periodStart = _previousPeriodStart(periodStart, periodType);
        }
    }

    function _aggregateNodeBetween(address nodeWallet, uint256 startTs, uint256 endTs)
        internal
        view
        returns (uint256 reward)
    {
        if (endTs < startTs) return 0;
        uint256 startHour = startTs / 3600;
        uint256 endHour = endTs / 3600;
        if (endHour < startHour || endHour - startHour > MAX_HOURS) return 0;
        mapping(uint256 => uint256) storage buckets = nodeHourlyReward[nodeWallet];
        for (uint256 i = startHour; i <= endHour; i++) {
            reward += buckets[i];
        }
    }

    function _aggregateBeneficiaryBetween(address beneficiary, uint256 startTs, uint256 endTs)
        internal
        view
        returns (uint256 reward)
    {
        if (endTs < startTs) return 0;
        uint256 startHour = startTs / 3600;
        uint256 endHour = endTs / 3600;
        if (endHour < startHour || endHour - startHour > MAX_HOURS) return 0;
        mapping(uint256 => uint256) storage buckets = beneficiaryHourlyReward[beneficiary];
        for (uint256 i = startHour; i <= endHour; i++) {
            reward += buckets[i];
        }
    }

    // ---- Period boundary math (UTC; copied from AdminStatsPeriodLib for self-containment) ---------------

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
        require(ym >= 0, "RewardIndexer: date underflow");
        ny = uint256(ym / 12);
        nm = uint256(ym % 12) + 1;
    }

    function _daysFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256 _days) {
        require(year >= 1970, "RewardIndexer: year<1970");
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
