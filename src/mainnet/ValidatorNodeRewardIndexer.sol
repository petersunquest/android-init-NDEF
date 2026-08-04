// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Reverse lookup into ValidatorDepositRedeem: a DePIN node wallet -> its current beneficiary (1:1).
interface IValidatorDepositRedeemBeneficiary {
    function getBeneficiaryByNodeWallet(address nodeWallet) external view returns (address);
}

/**
 * @title ValidatorNodeRewardIndexer
 * @notice Event-driven atomic CNET reward ledger for CoNET DePIN validator nodes — per NODE and per BENEFICIARY —
 *         with hour / day / week / month / quarter / year period statistics. Storage + query model is aligned
 *         with {BeamioIndexerDiamond} (StatsFacet): each report is ACCUMULATED into the hour bucket of the
 *         CURRENT block (`block.timestamp / 3600`), and larger periods are rolled up from the hour buckets at
 *         read time. Kept as a standalone companion to {ValidatorDepositRedeem} so the core contract stays
 *         within the EVM contract size limit (EIP-170).
 *
 * @dev WHY OFF-CHAIN MEASURED / RELAYER FED:
 *      Validator CNET rewards have two physical sources that the chain cannot self-attribute per node:
 *        1. Execution-layer rewards (priority fees + MEV) are paid straight to the validator's `fee_recipient`
 *           (the hot-updated beneficiary wallet) — they never touch this contract.
 *        2. Consensus-layer skim returns to ValidatorDepositRedeem's 0x01 `withdrawal_credentials` WITHOUT any
 *           per-pubkey memo, so an incoming native transfer cannot be mapped to a node on-chain.
 *      Therefore the owning validator node / beacon listener measures each node's reward off-chain and, WHENEVER
 *      it observes a reward event, writes the measured amount here via {reportNodeReward}. The listener NO LONGER
 *      needs to align to UTC hours or track hour boundaries locally: the contract buckets by the block's hour and
 *      accumulates. This ledger MOVES NO FUNDS; it is a display source for dashboards.
 *
 * @dev IDEMPOTENCY (aligned with BeamioIndexerDiamond.syncTokenAction txId dedup):
 *      Each report carries a non-zero {eventKey} (e.g. keccak256(txHash, logIndex) of the observed reward event).
 *      A given eventKey is consumed at most once, so listener restarts / reorgs / retries never double-count.
 *
 * @dev Reward "follows the node": the per-beneficiary credit for a (node, hour) is pinned to whoever the
 *      beneficiary is when that hour bucket first receives a report, recorded in {hourBeneficiary}, so a node
 *      transfer mid-window never re-attributes amounts already accumulated for that hour.
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

    // ---- Hourly ledger (accumulated, BeamioIndexerDiamond style) ---------------------------------------
    /// @notice node wallet => hourId (unix/3600) => CNET reward accumulated in that hour (18 decimals).
    mapping(address => mapping(uint256 => uint256)) public nodeHourlyReward;
    /// @notice beneficiary => hourId => aggregated CNET reward across the beneficiary's nodes in that hour.
    mapping(address => mapping(uint256 => uint256)) public beneficiaryHourlyReward;
    /// @notice node wallet => hourId => the beneficiary credited for that hour (pinned on first report; stable).
    mapping(address => mapping(uint256 => address)) public hourBeneficiary;
    /// @notice eventKey => consumed. Per-event idempotency guard (mirrors BeamioIndexerDiamond txId dedup).
    mapping(bytes32 => bool) public consumedEventKey;

    // ---- Pre-aggregated coarse buckets (O(1) reads; written alongside the hour bucket) -----------------
    /// @notice node => periodType (DAY/WEEK/MONTH/QUARTER/YEAR) => periodId => reward accumulated in that period.
    /// @dev    PERIOD_HOUR is intentionally NOT mirrored here; the hour granularity stays in {nodeHourlyReward}
    ///         (kept for ABI compatibility). Every {reportNodeReward} additionally accumulates the amount into the
    ///         DAY/WEEK/MONTH/QUARTER/YEAR bucket that contains the block's hour, so period summaries are a single
    ///         SLOAD per period instead of an hour-by-hour scan (no eth_call gas-cap blow-up over long windows).
    mapping(address => mapping(uint8 => mapping(uint256 => uint256))) public nodePeriodReward;
    /// @notice beneficiary => periodType => periodId => reward accumulated across the beneficiary's nodes.
    mapping(address => mapping(uint8 => mapping(uint256 => uint256))) public beneficiaryPeriodReward;

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
    /// @notice A reward event was accumulated into a node's current-hour bucket.
    /// @param nodeWallet      DePIN node operator wallet credited.
    /// @param beneficiary     Beneficiary credited for this (node, hour) (pinned on the hour's first report).
    /// @param hourId          UTC hour bucket (block.timestamp / 3600) the amount was added to.
    /// @param amount          CNET amount added by this report (18 decimals).
    /// @param newHourTotal    Running total of the node's bucket for {hourId} after this report.
    /// @param eventKey        The consumed off-chain reward event id (idempotency key).
    event NodeRewardReported(
        address indexed nodeWallet,
        address indexed beneficiary,
        uint256 indexed hourId,
        uint256 amount,
        uint256 newHourTotal,
        bytes32 eventKey
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
     * @notice Event-driven reward report: accumulate each measured amount into the CURRENT hour bucket
     *         (`block.timestamp / 3600`). The listener writes this whenever it observes a reward event; it does
     *         NOT pre-aggregate by UTC hour or pass an hourId — the contract buckets by the block's hour, exactly
     *         like {BeamioIndexerDiamond} buckets `syncTokenAction` by `block.timestamp / 3600`.
     * @dev Idempotent per {eventKey}: a previously consumed key is skipped (no double counting on restart/reorg).
     *      The credited beneficiary for a (node, hour) is pinned the first time that hour bucket is written
     *      (resolved from {redeem}); later reports in the same hour keep that beneficiary so a mid-window node
     *      transfer never re-attributes already-accumulated amounts.
     * @param eventKeys  Non-zero unique ids of the observed reward events (e.g. keccak256(txHash, logIndex)).
     * @param nodeWallets DePIN node operator wallets, parallel to {eventKeys}.
     * @param amounts     CNET reward amounts to add (18 decimals), parallel.
     * @return added      Number of entries actually applied (excludes already-consumed eventKeys).
     */
    function reportNodeReward(
        bytes32[] calldata eventKeys,
        address[] calldata nodeWallets,
        uint256[] calldata amounts
    ) external onlyAdmin returns (uint256 added) {
        uint256 n = eventKeys.length;
        require(n > 0, "RewardIndexer: empty");
        require(nodeWallets.length == n && amounts.length == n, "RewardIndexer: length mismatch");
        uint256 hourId = block.timestamp / 3600;
        for (uint256 i = 0; i < n; i++) {
            bytes32 key = eventKeys[i];
            require(key != bytes32(0), "RewardIndexer: zero eventKey");
            if (consumedEventKey[key]) continue; // idempotent: skip already-applied event
            consumedEventKey[key] = true;
            _addNodeRewardHour(nodeWallet_(nodeWallets[i]), hourId, amounts[i], key);
            added++;
        }
    }

    /// @dev tiny helper to validate node address once before storage writes (keeps stack small).
    function nodeWallet_(address nodeWallet) private pure returns (address) {
        require(nodeWallet != address(0), "RewardIndexer: zero node");
        return nodeWallet;
    }

    function _addNodeRewardHour(address nodeWallet, uint256 hourId, uint256 amount, bytes32 eventKey) internal {
        if (amount == 0) {
            // Still emit so the off-chain ledger can mark the event consumed.
            emit NodeRewardReported(nodeWallet, hourBeneficiary[nodeWallet][hourId], hourId, 0, nodeHourlyReward[nodeWallet][hourId], eventKey);
            return;
        }

        // Resolve / pin the beneficiary credited for this (node, hour) on its first write.
        address ben = hourBeneficiary[nodeWallet][hourId];
        if (ben == address(0)) {
            if (address(redeem) != address(0)) {
                ben = redeem.getBeneficiaryByNodeWallet(nodeWallet);
            }
            hourBeneficiary[nodeWallet][hourId] = ben; // may stay address(0) if node not yet bound
        }

        // Accumulate node bucket + cumulative.
        uint256 newHourTotal = nodeHourlyReward[nodeWallet][hourId] + amount;
        nodeHourlyReward[nodeWallet][hourId] = newHourTotal;
        nodeCumulativeReward[nodeWallet] += amount;
        totalCumulativeReward += amount;
        if (ben != address(0)) {
            beneficiaryHourlyReward[ben][hourId] += amount;
            beneficiaryCumulativeReward[ben] += amount;
        }

        // Mirror the amount into the coarse DAY/WEEK/MONTH/QUARTER/YEAR buckets containing this hour, so period
        // reads stay O(1). The hour's start (hourId*3600) lies in the same calendar day/week/month/quarter/year as
        // the block (an hour bucket never straddles a higher-period boundary), so deriving the ids from it is exact.
        _accumulatePeriodBuckets(nodeWallet, ben, hourId * 3600, amount);

        // Track first/last reported hour bounds (only widen).
        uint64 h64 = uint64(hourId);
        if (nodeFirstHour[nodeWallet] == 0 || h64 < nodeFirstHour[nodeWallet]) nodeFirstHour[nodeWallet] = h64;
        if (h64 > nodeLastHour[nodeWallet]) nodeLastHour[nodeWallet] = h64;
        if (ben != address(0)) {
            if (beneficiaryFirstHour[ben] == 0 || h64 < beneficiaryFirstHour[ben]) beneficiaryFirstHour[ben] = h64;
            if (h64 > beneficiaryLastHour[ben]) beneficiaryLastHour[ben] = h64;
        }

        emit NodeRewardReported(nodeWallet, ben, hourId, amount, newHourTotal, eventKey);
    }

    /// @dev Add {amount} to the DAY/WEEK/MONTH/QUARTER/YEAR buckets that contain {ts} for the node and (if set) ben.
    function _accumulatePeriodBuckets(address nodeWallet, address ben, uint256 ts, uint256 amount) internal {
        uint256 dayId = ts / 1 days;
        uint256 weekId = (dayId + 3) / 7; // Monday-aligned week index (epoch day 0 = Thursday)
        (uint256 y, uint256 m, ) = _daysToDate(dayId);
        uint256 monthId = y * 12 + (m - 1);
        uint256 quarterId = y * 4 + ((m - 1) / 3);

        nodePeriodReward[nodeWallet][PERIOD_DAY][dayId] += amount;
        nodePeriodReward[nodeWallet][PERIOD_WEEK][weekId] += amount;
        nodePeriodReward[nodeWallet][PERIOD_MONTH][monthId] += amount;
        nodePeriodReward[nodeWallet][PERIOD_QUARTER][quarterId] += amount;
        nodePeriodReward[nodeWallet][PERIOD_YEAR][y] += amount;

        if (ben != address(0)) {
            beneficiaryPeriodReward[ben][PERIOD_DAY][dayId] += amount;
            beneficiaryPeriodReward[ben][PERIOD_WEEK][weekId] += amount;
            beneficiaryPeriodReward[ben][PERIOD_MONTH][monthId] += amount;
            beneficiaryPeriodReward[ben][PERIOD_QUARTER][quarterId] += amount;
            beneficiaryPeriodReward[ben][PERIOD_YEAR][y] += amount;
        }
    }

    /// @dev The bucket id of the period (of {periodType}) that contains {ts}. Matches {_accumulatePeriodBuckets}.
    function _periodId(uint256 ts, uint8 periodType) internal pure returns (uint256) {
        if (periodType == PERIOD_HOUR) return ts / 3600;
        if (periodType == PERIOD_DAY) return ts / 1 days;
        if (periodType == PERIOD_WEEK) return (ts / 1 days + 3) / 7;
        (uint256 y, uint256 m, ) = _daysToDate(ts / 1 days);
        if (periodType == PERIOD_MONTH) return y * 12 + (m - 1);
        if (periodType == PERIOD_QUARTER) return y * 4 + ((m - 1) / 3);
        return y; // PERIOD_YEAR
    }

    /// @dev O(1) node period bucket read (HOUR reads the legacy hour map; others read the coarse map).
    function _nodeBucket(address nodeWallet, uint8 periodType, uint256 periodId) internal view returns (uint256) {
        if (periodType == PERIOD_HOUR) return nodeHourlyReward[nodeWallet][periodId];
        return nodePeriodReward[nodeWallet][periodType][periodId];
    }

    /// @dev O(1) beneficiary period bucket read.
    function _beneficiaryBucket(address beneficiary, uint8 periodType, uint256 periodId) internal view returns (uint256) {
        if (periodType == PERIOD_HOUR) return beneficiaryHourlyReward[beneficiary][periodId];
        return beneficiaryPeriodReward[beneficiary][periodType][periodId];
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
        // O(1): the whole-period total is the pre-aggregated bucket for the period containing {anchorTs}.
        uint256 periodId = _periodId(anchorTs, periodType);
        return isBeneficiary
            ? _beneficiaryBucket(subject, periodType, periodId)
            : _nodeBucket(subject, periodType, periodId);
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
            // O(1) per period: read the pre-aggregated bucket (periodStart lies within the period).
            uint256 periodId = _periodId(periodStart, periodType);
            reports[i].reward = isBeneficiary
                ? _beneficiaryBucket(subject, periodType, periodId)
                : _nodeBucket(subject, periodType, periodId);
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
