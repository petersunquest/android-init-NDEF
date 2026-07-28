// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

/* ---------- Minimal Date helpers (month/year boundaries) ---------- */
library DateTimeLib {
    function _daysFromDate(uint year, uint month, uint day) internal pure returns (uint _days) {
        require(year >= 1970);
        int _year = int(year);
        int _month = int(month);
        int _day = int(day);

        int __days = _day
          - 32075
          + 1461 * (_year + 4800 + (_month - 14) / 12) / 4
          + 367 * (_month - 2 - (_month - 14) / 12 * 12) / 12
          - 3 * ((_year + 4900 + (_month - 14) / 12) / 100) / 4
          - 2440588;

        return uint(__days);
    }
    function timestampFromDate(uint year, uint month, uint day) internal pure returns (uint timestamp) {
        return _daysFromDate(year, month, day) * 1 days;
    }
    function timestampToDate(uint timestamp) internal pure returns (uint year, uint month, uint day) {
        uint __days = timestamp / 1 days;
        int L = int(__days) + 68569 + 2440588;
        int N = 4 * L / 146097;
        L = L - (146097 * N + 3) / 4;
        int _year = 4000 * (L + 1) / 1461001;
        L = L - 1461 * _year / 4 + 31;
        int _month = 80 * L / 2447;
        int _day = L - 2447 * _month / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;
        year = uint(_year); month = uint(_month); day = uint(_day);
    }
}

contract ConetGB1155 is ERC1155, ERC1155Supply, AccessControl {
    using Strings for uint256;

    /* ---------------- Roles ---------------- */
    bytes32 public constant ISSUER_ROLE    = keccak256("ISSUER_ROLE");
    bytes32 public constant OPERATOR_ROLE  = keccak256("OPERATOR_ROLE");

    /* ---------------- Constants ---------------- */
    uint256 public constant TOKENID_TOTAL = 0; // id=0: 总量(净量)

    /* ---------------- Hour timeline ---------------- */
    uint64  public immutable startTime;   // 对齐整点的起始时间（秒，UTC）
    uint64  public immutable startHourId; // 通常设为 1

    struct HourMeta {
        uint64 startBlock;
        uint64 endBlock;
        uint64 startTime;   // hour start (sec)
        bool   initialized;
    }
    mapping(uint256 => HourMeta) public hourMeta; // hourId => meta

    /* ---------------- Hour indices (per-hour gross issuance) ---------------- */
    mapping(uint256 => address[]) private _hourRecipients;                 // hourId => addrs
    mapping(uint256 => mapping(address => uint256)) private _hourAmount;   // hourId => (user => GB18)
    mapping(uint256 => mapping(address => bool))    private _hourSeen;     // hourId => (user => seen)

    /* ---------------- Day/Week/Month/Year gross indices ---------------- */
    mapping(uint64 => address[]) private _dayRecipients;
    mapping(uint64 => mapping(address => uint256)) private _dayAmount;
    mapping(uint64 => mapping(address => bool))    private _daySeen;
    mapping(uint64 => uint256)                     private _dayTotal;

    mapping(uint64 => address[]) private _weekRecipients;
    mapping(uint64 => mapping(address => uint256)) private _weekAmount;
    mapping(uint64 => mapping(address => bool))    private _weekSeen;
    mapping(uint64 => uint256)                     private _weekTotal;

    mapping(uint64 => address[]) private _monthRecipients;
    mapping(uint64 => mapping(address => uint256)) private _monthAmount;
    mapping(uint64 => mapping(address => bool))    private _monthSeen;
    mapping(uint64 => uint256)                     private _monthTotal;

    mapping(uint64 => address[]) private _yearRecipients;
    mapping(uint64 => mapping(address => uint256)) private _yearAmount;
    mapping(uint64 => mapping(address => bool))    private _yearSeen;
    mapping(uint64 => uint256)                     private _yearTotal;

    /* ---------------- Events ---------------- */
    event Issued(address indexed issuer, address indexed to, uint256 amountGB18, uint256 indexed hourId);
    event BatchIssued(address indexed issuer, uint256 indexed hourId, uint256 count, uint256 totalAmountGB18);
    event RevokedTotal(address indexed from, uint256 amountGB18);
    event HourInitialized(uint256 indexed hourId, uint64 startBlock, uint64 startTime);
    event HourFinalized(uint256 indexed hourId, uint64 endBlock);
    event IssuerAdded(address indexed account);
    event IssuerRemoved(address indexed account);

    constructor(uint64 _startTimeAlignedToHour, uint64 _startHourId) ERC1155("") {
        require(_startTimeAlignedToHour % 3600 == 0, "start not hour-aligned");
        startTime   = _startTimeAlignedToHour;
        startHourId = _startHourId;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ---------------- Issuer whitelist management ---------------- */
    function addIssuers(address[] calldata accounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i=0;i<accounts.length;i++){
            address a = accounts[i];
            require(a != address(0), "zero addr");
            if (!hasRole(ISSUER_ROLE, a)) {
                _grantRole(ISSUER_ROLE, a);
                emit IssuerAdded(a);
            }
        }
    }
    function removeIssuers(address[] calldata accounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i=0;i<accounts.length;i++){
            address a = accounts[i];
            if (hasRole(ISSUER_ROLE, a)) {
                _revokeRole(ISSUER_ROLE, a);
                emit IssuerRemoved(a);
            }
        }
    }
    function addIssuer(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "zero addr");
        _grantRole(ISSUER_ROLE, account);
        emit IssuerAdded(account);
    }
    function removeIssuer(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(ISSUER_ROLE, account);
        emit IssuerRemoved(account);
    }
    function isIssuer(address account) external view returns (bool) {
        return hasRole(ISSUER_ROLE, account);
    }

    /* ---------------- Issue / Revoke ---------------- */

    struct PeriodKeys { uint64 day; uint64 week; uint64 month; uint64 year; }

    function _currentPeriodKeys() internal view returns (PeriodKeys memory k) {
        k.day   = uint64(_todayStartUTC());
        k.week  = uint64(_weekStartUTC(block.timestamp));
        k.month = uint64(_monthStartUTC(block.timestamp));
        k.year  = uint64(_yearStartUTC(block.timestamp));
    }

    /// 发行：同时记入 id=0(净) 与 当前小时(毛)；并更新小时/日/周/月/年索引
    function issueGB(address to, uint256 amountGB18) external onlyRole(ISSUER_ROLE) {
        require(to != address(0), "zero addr");
        require(amountGB18 > 0, "amount=0");

        uint256 hourId = currentHourId();
        _initHourIfNeeded(hourId);

        _mint(to, TOKENID_TOTAL, amountGB18, ""); // 总量（净）
        _mint(to, hourId,        amountGB18, ""); // 小时（毛）

        if (!_hourSeen[hourId][to]) { _hourSeen[hourId][to] = true; _hourRecipients[hourId].push(to); }
        _hourAmount[hourId][to] += amountGB18;

        _accumulatePK(to, amountGB18, _currentPeriodKeys());

        emit Issued(msg.sender, to, amountGB18, hourId);
    }

    /// 批量发行：逐个地址处理，更新所有索引与事件
    function issueGBBatch(address[] calldata wallets, uint256[] calldata issues)
        external onlyRole(ISSUER_ROLE)
    {
        require(wallets.length == issues.length && wallets.length > 0, "bad inputs");

        uint256 hourId = currentHourId();
        _initHourIfNeeded(hourId);

        PeriodKeys memory k = _currentPeriodKeys();
        uint256 totalBatch;

        for (uint256 i=0;i<wallets.length;i++){
            address to = wallets[i];
            uint256 amountGB18 = issues[i];
            require(to != address(0), "zero addr");
            require(amountGB18 > 0, "amount=0");

            _mint(to, TOKENID_TOTAL, amountGB18, "");
            _mint(to, hourId,        amountGB18, "");

            if (!_hourSeen[hourId][to]) { _hourSeen[hourId][to] = true; _hourRecipients[hourId].push(to); }
            _hourAmount[hourId][to] += amountGB18;

            _accumulatePK(to, amountGB18, k);

            totalBatch += amountGB18;
            emit Issued(msg.sender, to, amountGB18, hourId);
        }

        emit BatchIssued(msg.sender, hourId, wallets.length, totalBatch);
    }

    /// 撤销：仅从 id=0（净总量）扣减；不影响小时/日/周/月/年的毛发行历史
    function revokeTotalOnly(address from, uint256 amountGB18) external onlyRole(ISSUER_ROLE) {
        require(from != address(0), "zero addr");
        require(amountGB18 > 0, "amount=0");
        _burn(from, TOKENID_TOTAL, amountGB18);
        emit RevokedTotal(from, amountGB18);
    }

    /* ---------------- Hour finalize ---------------- */
    function finalizeHour(uint256 hourId, uint64 endBlock) external onlyRole(OPERATOR_ROLE) {
        HourMeta storage m = hourMeta[hourId];
        require(m.initialized, "hour not init");
        require(endBlock != 0, "endBlock=0");
        m.endBlock = endBlock;
        emit HourFinalized(hourId, endBlock);
    }

    /* ---------------- Read: Hour (deviation) ---------------- */

    function _thisHourStartUTC() internal view returns (uint256) {
        return (block.timestamp / 3600) * 3600;
    }
    function _hourIdByDeviation(uint256 deviation) internal view returns (uint256) {
        return hourIdAt(_thisHourStartUTC() - deviation * 1 hours);
    }

    function hourlyWalletsCount(uint256 deviation) external view returns (uint256) {
        return _hourRecipients[_hourIdByDeviation(deviation)].length;
    }

    function hourlyRecipientsPage(uint256 deviation, uint256 start, uint256 limit)
        external view returns (address[] memory addrs, uint256[] memory amounts)
    {
        uint256 hid = _hourIdByDeviation(deviation);
        address[] storage all = _hourRecipients[hid];
        uint256 n = all.length;

        if (start >= n) {
            return (new address[](0), new uint256[](0));
        }
        uint256 end = start + limit;
        if (end > n) end = n;

        addrs   = new address[](end - start);
        amounts = new uint256[](end - start);

        for (uint256 i = start; i < end; i++) {
            addrs[i - start]   = all[i];
            amounts[i - start] = _hourAmount[hid][all[i]];
        }
    }

    function hourlyTotalIssued(uint256 deviation) external view returns (uint256) {
        return totalSupply(_hourIdByDeviation(deviation));
    }

    /* ---------------- Read: Day/Week/Month/Year (deviation) ---------------- */

    function _alignDay(uint256 ts) internal pure returns (uint256) { return (ts / 1 days) * 1 days; }
    function _todayStartUTC() internal view returns (uint256) { return _alignDay(block.timestamp); }

    // 周一为一周起点（UTC）
    function _weekStartUTC(uint256 ts) internal pure returns (uint256) {
        uint256 dayStart = _alignDay(ts);
        uint256 daysFromMon = ((dayStart / 1 days) + 3) % 7; // epoch 是周四
        return dayStart - daysFromMon * 1 days;
    }

    function _monthStartUTC(uint256 ts) internal pure returns (uint256) {
        (uint y, uint m, ) = DateTimeLib.timestampToDate(ts);
        return DateTimeLib.timestampFromDate(y, m, 1);
    }
    function _yearStartUTC(uint256 ts) internal pure returns (uint256) {
        (uint y, , ) = DateTimeLib.timestampToDate(ts);
        return DateTimeLib.timestampFromDate(y, 1, 1);
    }

    function _dayKeyByDeviation(uint256 deviation) internal view returns (uint64) {
        return uint64(_todayStartUTC() - deviation * 1 days);
    }
    function dayWalletsCount(uint256 deviation) external view returns (uint256) {
        return _dayRecipients[_dayKeyByDeviation(deviation)].length;
    }

    function dayRecipientsPage(uint256 deviation, uint256 start, uint256 limit)
        external view returns (address[] memory addrs, uint256[] memory amounts)
    {
        uint64 k = _dayKeyByDeviation(deviation);
        address[] storage all = _dayRecipients[k];
        uint256 n = all.length;

        if (start >= n) {
            return (new address[](0), new uint256[](0));
        }
        uint256 end = start + limit;
        if (end > n) end = n;

        addrs   = new address[](end - start);
        amounts = new uint256[](end - start);

        for (uint256 i = start; i < end; i++) {
            addrs[i - start]   = all[i];
            amounts[i - start] = _dayAmount[k][all[i]];
        }
    }
    function dayTotalIssued(uint256 deviation) external view returns (uint256) {
        return _dayTotal[_dayKeyByDeviation(deviation)];
    }

    function _weekKeyByDeviation(uint256 deviation) internal view returns (uint64) {
        return uint64(_weekStartUTC(block.timestamp) - deviation * 7 days);
    }
    function weeklyWalletsCount(uint256 deviation) external view returns (uint256) {
        return _weekRecipients[_weekKeyByDeviation(deviation)].length;
    }
    function weeklyRecipientsPage(uint256 deviation, uint256 start, uint256 limit)
        external view returns (address[] memory addrs, uint256[] memory amounts)
    {
        uint64 k = _weekKeyByDeviation(deviation);
        address[] storage all = _weekRecipients[k];
        uint256 n = all.length;

        if (start >= n) {
            return (new address[](0), new uint256[](0));
        }
        uint256 end = start + limit;
        if (end > n) end = n;

        addrs   = new address[](end - start);
        amounts = new uint256[](end - start);

        for (uint256 i = start; i < end; i++) {
            addrs[i - start]   = all[i];
            amounts[i - start] = _weekAmount[k][all[i]];
        }
    }
    function weeklyTotalIssued(uint256 deviation) external view returns (uint256) {
        return _weekTotal[_weekKeyByDeviation(deviation)];
    }

    function _monthKeyByDeviation(uint256 deviation) internal view returns (uint64) {
        uint256 mStart = _monthStartUTC(block.timestamp);
        for (uint256 i = 0; i < deviation; i++) { mStart = _monthStartUTC(mStart - 1); }
        return uint64(mStart);
    }

    function monthlyWalletsCount(uint256 deviation) external view returns (uint256) {
        return _monthRecipients[_monthKeyByDeviation(deviation)].length;
    }
    function monthlyRecipientsPage(uint256 deviation, uint256 start, uint256 limit)
        external view returns (address[] memory addrs, uint256[] memory amounts)
    {
        uint64 k = _monthKeyByDeviation(deviation);
        address[] storage all = _monthRecipients[k];
        uint256 n = all.length;

        if (start >= n) {
            return (new address[](0), new uint256[](0));
        }
        uint256 end = start + limit;
        if (end > n) end = n;

        addrs   = new address[](end - start);
        amounts = new uint256[](end - start);

        for (uint256 i = start; i < end; i++) {
            addrs[i - start]   = all[i];
            amounts[i - start] = _monthAmount[k][all[i]];
        }
    }
    function monthlyTotalIssued(uint256 deviation) external view returns (uint256) {
        return _monthTotal[_monthKeyByDeviation(deviation)];
    }

    function _yearKeyByDeviation(uint256 deviation) internal view returns (uint64) {
        uint256 yStart = _yearStartUTC(block.timestamp);
        for (uint256 i = 0; i < deviation; i++) { yStart = _yearStartUTC(yStart - 1); }
        return uint64(yStart);
    }
    function yearlyWalletsCount(uint256 deviation) external view returns (uint256) {
        return _yearRecipients[_yearKeyByDeviation(deviation)].length;
    }

    function yearlyRecipientsPage(uint256 deviation, uint256 start, uint256 limit)
        external view returns (address[] memory addrs, uint256[] memory amounts)
    {
        uint64 k = _yearKeyByDeviation(deviation);
        address[] storage all = _yearRecipients[k];
        uint256 n = all.length;

        if (start >= n) {
            return (new address[](0), new uint256[](0));
        }
        uint256 end = start + limit;
        if (end > n) end = n;

        addrs   = new address[](end - start);
        amounts = new uint256[](end - start);

        for (uint256 i = start; i < end; i++) {
            addrs[i - start]   = all[i];
            amounts[i - start] = _yearAmount[k][all[i]];
        }
    }

    function yearlyTotalIssued(uint256 deviation) external view returns (uint256) {
        return _yearTotal[_yearKeyByDeviation(deviation)];
    }

    /* ---------------- Time/ID helpers ---------------- */

    function currentHourId() public view returns (uint256) {
        return uint256(startHourId) + (block.timestamp - uint256(startTime)) / 3600;
    }
    function hourIdAt(uint256 ts) public view returns (uint256) {
        require(ts >= startTime, "before start");
        return uint256(startHourId) + (ts - uint256(startTime)) / 3600;
    }
    function hourStartTime(uint256 hourId) public view returns (uint256) {
        require(hourId >= startHourId, "invalid hourId");
        return uint256(startTime) + (hourId - startHourId) * 3600;
    }

    /* ---------------- Hour helpers ---------------- */

    function hourExists(uint256 hourId) external view returns (bool) {
        return hourMeta[hourId].initialized || totalSupply(hourId) > 0;
    }

    function hourInfo(uint256 hourId)
        external view
        returns (
            bool initialized,
            uint64 startBlock,
            uint64 endBlock,
            uint256 hourStartTs,
            uint256 recipientsCount,
            uint256 totalIssuedGB18
        )
    {
        HourMeta memory m = hourMeta[hourId];
        initialized      = m.initialized;
        startBlock       = m.startBlock;
        endBlock         = m.endBlock;
        hourStartTs      = hourStartTime(hourId);
        recipientsCount  = _hourRecipients[hourId].length;
        totalIssuedGB18  = totalSupply(hourId);
    }

    /* ---------------- Internal: accumulate D/W/M/Y indices ---------------- */

    function _accumulatePK(address to, uint256 amount, PeriodKeys memory k) internal {
        if (!_daySeen[k.day][to])   { _daySeen[k.day][to] = true;   _dayRecipients[k.day].push(to); }
        _dayAmount[k.day][to] += amount;   _dayTotal[k.day] += amount;

        if (!_weekSeen[k.week][to]) { _weekSeen[k.week][to] = true; _weekRecipients[k.week].push(to); }
        _weekAmount[k.week][to] += amount; _weekTotal[k.week] += amount;

        if (!_monthSeen[k.month][to]) { _monthSeen[k.month][to] = true; _monthRecipients[k.month].push(to); }
        _monthAmount[k.month][to] += amount; _monthTotal[k.month] += amount;

        if (!_yearSeen[k.year][to]) { _yearSeen[k.year][to] = true; _yearRecipients[k.year].push(to); }
        _yearAmount[k.year][to] += amount; _yearTotal[k.year] += amount;
    }

    /* ---------------- Non-transferable enforcement ---------------- */

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        if (from != address(0) && to != address(0)) {
            revert("non-transferable");
        }
        super._update(from, to, ids, values);
    }

    /* ---------------- Dynamic URI ---------------- */

    function _metaTotal(uint256 id) internal pure returns (bytes memory) {
        // 尽量少的拼接片段，减少 ABI 编码临时值
        return abi.encodePacked(
            '{"name":"CONET Total GB",',
            '"description":"Net total GBytes since start. 1e18 = 1 GB. Revoke affects only id=0.",',
            '"tokenId":"', id.toString(), '",',
            '"decimals":"18","unit":"GB","type":"total"}'
        );
    }

    function _metaHour(uint256 id) internal view returns (bytes memory) {
        HourMeta memory m = hourMeta[id];
        return abi.encodePacked(
            '{"name":"CONET Hourly GB #', id.toString(), '",',
            '"description":"Hourly gross GB issuance. 1e18 = 1 GB.",',
            '"tokenId":"', id.toString(), '",',
            '"decimals":"18","unit":"GB","type":"hourly",',
            '"hour_start_time":"', hourStartTime(id).toString(), '",',
            '"start_block":"', uint256(m.startBlock).toString(), '",',
            '"end_block":"', uint256(m.endBlock).toString(), '"}'
        );
    }

    // ===== Wallet-specific issued amount queries =====

    // ---- Hourly ----
    function hourlyIssuedOf(address account, uint256 deviation) external view returns (uint256) {
        return _hourAmount[_hourIdByDeviation(deviation)][account];
    }
    function issuedThisHourOf(address account) external view returns (uint256) {
        return _hourAmount[_hourIdByDeviation(0)][account];
    }

    // ---- Daily (UTC natural day) ----
    function dayIssuedOf(address account, uint256 deviation) external view returns (uint256) {
        return _dayAmount[_dayKeyByDeviation(deviation)][account];
    }
    function issuedTodayOf(address account) external view returns (uint256) {
        return _dayAmount[_dayKeyByDeviation(0)][account];
    }

    // ---- Weekly (Mon 00:00 UTC as week start) ----
    function weeklyIssuedOf(address account, uint256 deviation) external view returns (uint256) {
        return _weekAmount[_weekKeyByDeviation(deviation)][account];
    }
    function issuedThisWeekOf(address account) external view returns (uint256) {
        return _weekAmount[_weekKeyByDeviation(0)][account];
    }

    // ---- Monthly ----
    function monthlyIssuedOf(address account, uint256 deviation) external view returns (uint256) {
        return _monthAmount[_monthKeyByDeviation(deviation)][account];
    }
    function issuedThisMonthOf(address account) external view returns (uint256) {
        return _monthAmount[_monthKeyByDeviation(0)][account];
    }

    // ---- Yearly ----
    function yearlyIssuedOf(address account, uint256 deviation) external view returns (uint256) {
        return _yearAmount[_yearKeyByDeviation(deviation)][account];
    }
    function issuedThisYearOf(address account) external view returns (uint256) {
        return _yearAmount[_yearKeyByDeviation(0)][account];
    }

    function uri(uint256 id) public view override returns (string memory out) {
        bytes memory meta = (id == TOKENID_TOTAL) ? _metaTotal(id) : _metaHour(id);
        out = string(abi.encodePacked("data:application/json;base64,", Base64.encode(meta)));
    }

    function wasHourlyRecipient(address account, uint256 deviation) external view returns (bool) {
        uint256 hid = _hourIdByDeviation(deviation);
        return _hourSeen[hid][account];
    }

    /* ---------------- Hour init ---------------- */

    function _initHourIfNeeded(uint256 hourId) internal {
        HourMeta storage m = hourMeta[hourId];
        if (!m.initialized) {
            m.initialized = true;
            m.startBlock  = uint64(block.number);
            m.startTime   = uint64(hourStartTime(hourId));
            emit HourInitialized(hourId, m.startBlock, m.startTime);
        }
    }

    /* ---------------- Interface support ---------------- */

    function supportsInterface(bytes4 iid)
        public view override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(iid);
    }
}
