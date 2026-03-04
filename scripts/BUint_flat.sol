[dotenv@17.3.1] injecting env (0) from .env -- tip: 🔐 prevent committing .env to code: https://dotenvx.com/precommit
// Sources flattened with hardhat v3.1.9 https://hardhat.org

// SPDX-License-Identifier: MIT

// File src/b-unit/BUint.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Beamio B-Units 燃料合约 (CoNET L1)
 * @dev 深度重载的 ERC20 实现。包含：双水池分类账本、限制转账(SBT特性)、瀑布流核销与真实收益分润机制。
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract BeamioBUnits is IERC20 {
    string public constant name = "Beamio Units";
    string public constant symbol = "B-UNITS";
    
    // 采用 6 位精度 (与 USDC 原生精度保持一致)
    // 也能完美防止 5% 分润计算截断 (例: 2 Units = 2,000,000, 5% = 100,000，无精度丢失)
    uint8 public constant decimals = 6; 

    uint256 private _totalSupply;

    // --- 核心创新：双极结构分类账本 ---
    struct FuelBalance {
        uint128 freePool; // 免费池 (染色 A：无 USDC 背书，无分润)
        uint128 paidPool; // 付费池 (染色 B：真实 USDC 背书，触发 5% 分润)
    }

    // 用户地址映射到双水池结构
    mapping(address => FuelBalance) private _fuelBalances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // --- 权限控制：统一 Admin Group ---
    mapping(address => bool) public admins;

    // --- 焚烧统计：累计已燃烧量 (6 位精度) ---
    uint256 public totalFreeBurned;  // 免费池累计焚烧量
    uint256 public totalPaidBurned;  // 付费池累计焚烧量

    // --- 每小时原子 mint/burn 记账 (6 位精度)，统一 UTC 自然时间 ---
    struct PeriodStats {
        uint256 mint;
        uint256 burn;
    }
    mapping(uint256 => PeriodStats) private _hourlyStats;   // slot = ts/3600，整点 UTC
    mapping(uint256 => PeriodStats) private _dailyStats;    // slot = ts/86400，0:00 UTC
    mapping(uint256 => PeriodStats) private _weeklyStats;   // slot = (ts+WEEK_OFFSET)/604800，周一 0:00 UTC
    mapping(uint256 => PeriodStats) private _monthlyStats; // slot = 自然月，1 日 0:00 UTC
    mapping(uint256 => PeriodStats) private _quarterlyStats; // slot = 自然季度，1/4/7/10 月 1 日 0:00 UTC
    mapping(uint256 => PeriodStats) private _yearlyStats;  // slot = 自然年，1 月 1 日 0:00 UTC

    uint256 private constant HOUR = 3600;
    uint256 private constant DAY = 86400;
    uint256 private constant WEEK = 604800;
    /// @dev Jan 1 1970 00:00 UTC 为周四，周一 0:00 UTC 为 Dec 29 1969 = -345600
    uint256 private constant WEEK_OFFSET = 345600;

    // --- 自定义业务事件 ---
    event MintReward(address indexed to, uint256 amount);
    event MintPaid(address indexed to, uint256 amount);
    event FuelConsumed(address indexed user, uint256 amount);
    // 跨链节点分润事件 (监听此事件释放 USDC)
    event NodeYieldGenerated(address indexed user, uint256 paidBurned, uint256 yieldAmount);
    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);

    modifier onlyAdmin() {
        require(admins[msg.sender], "B-Units: Caller is not an admin");
        _;
    }

    constructor() {
        admins[msg.sender] = true;
    }

    function _recordMint(uint256 amount) internal {
        uint256 ts = block.timestamp;
        _hourlyStats[ts / HOUR].mint += amount;
        _dailyStats[ts / DAY].mint += amount;
        _weeklyStats[(ts + WEEK_OFFSET) / WEEK].mint += amount;
        _monthlyStats[_getMonthSlot(ts)].mint += amount;
        _quarterlyStats[_getQuarterSlot(ts)].mint += amount;
        _yearlyStats[_getYearSlot(ts)].mint += amount;
    }

    function _recordBurn(uint256 amount) internal {
        uint256 ts = block.timestamp;
        _hourlyStats[ts / HOUR].burn += amount;
        _dailyStats[ts / DAY].burn += amount;
        _weeklyStats[(ts + WEEK_OFFSET) / WEEK].burn += amount;
        _monthlyStats[_getMonthSlot(ts)].burn += amount;
        _quarterlyStats[_getQuarterSlot(ts)].burn += amount;
        _yearlyStats[_getYearSlot(ts)].burn += amount;
    }

    function _isLeap(uint256 year) internal pure returns (bool) {
        return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
    }

    function _getDaysInMonth(uint256 month, uint256 year) internal pure returns (uint256) {
        if (month == 1) return _isLeap(year) ? 29 : 28; // Feb
        if (month == 0 || month == 2 || month == 4 || month == 6 || month == 7 || month == 9 || month == 11) return 31;
        return 30;
    }

    /// @dev 返回自然月 slot，0 = Jan 1970
    function _getMonthSlot(uint256 timestamp) internal pure returns (uint256) {
        uint256 d = timestamp / DAY;
        uint256 y = 1970;
        for (;;) {
            uint256 daysInYear = _isLeap(y) ? 366 : 365;
            if (d < daysInYear) break;
            d -= daysInYear;
            y++;
        }
        uint256 month = 0;
        for (uint256 m = 0; m < 12; m++) {
            uint256 dim = _getDaysInMonth(m, y);
            if (d < dim) break;
            d -= dim;
            month++;
        }
        return (y - 1970) * 12 + month;
    }

    /// @dev 返回自然季度 slot，0 = Q1 1970 (Jan-Mar)
    function _getQuarterSlot(uint256 timestamp) internal pure returns (uint256) {
        return _getMonthSlot(timestamp) / 3;
    }

    /// @dev 返回自然年 slot，0 = 1970
    function _getYearSlot(uint256 timestamp) internal pure returns (uint256) {
        uint256 d = timestamp / DAY;
        uint256 y = 1970;
        for (;;) {
            uint256 daysInYear = _isLeap(y) ? 366 : 365;
            if (d < daysInYear) break;
            d -= daysInYear;
            y++;
        }
        return y - 1970;
    }

    // --- Admin Group 管理 ---
    function addAdmin(address account) external onlyAdmin {
        require(account != address(0), "B-Units: Invalid admin address");
        admins[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyAdmin {
        require(account != msg.sender, "B-Units: Cannot remove self");
        admins[account] = false;
        emit AdminRemoved(account);
    }

    // ==========================================
    // ERC20 标准读取接口 (完美兼容前端与钱包)
    // ==========================================

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev 前端读取时，将双水池合并为一个总数展示，实现“外表单币种，内胆双账本”
     */
    function balanceOf(address account) public view override returns (uint256) {
        return uint256(_fuelBalances[account].freePool) + uint256(_fuelBalances[account].paidPool);
    }

    /**
     * @dev 返回用户 B-Unit 明细：总数、免费池、USDC 购买（付费池）。6 位精度。
     */
    function balanceOfAll(address account) external view returns (uint256 total, uint256 free, uint256 paid) {
        FuelBalance storage bal = _fuelBalances[account];
        free = uint256(bal.freePool);
        paid = uint256(bal.paidPool);
        total = free + paid;
    }

    // ==========================================
    // 阻断灰产：灵魂绑定拦截 (SBT 特性)
    // ==========================================

    function transfer(address /* to */, uint256 /* value */) public pure override returns (bool) {
        revert("B-Units: Peer-to-peer transfers are locked for security.");
    }

    function transferFrom(address /* from */, address /* to */, uint256 /* value */) public pure override returns (bool) {
        revert("B-Units: Delegated transfers are locked.");
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function allowance(address _owner, address spender) public view override returns (uint256) {
        return _allowances[_owner][spender];
    }

    // ==========================================
    // 铸币权限与资产染色 (DNA Tracking)
    // ==========================================

    /**
     * @dev 铸造生态奖励 (免费池) - 不产生未来分润
     */
    function mintReward(address to, uint256 amount) external onlyAdmin {
        require(amount <= type(uint128).max, "B-Units: Amount exceeds uint128");
        _fuelBalances[to].freePool += uint128(amount);
        _totalSupply += amount;
        _recordMint(amount);
        emit MintReward(to, amount);
        emit Transfer(address(0), to, amount);
    }

    /**
     * @dev 铸造法币兑换 (付费池) - 带有分润染色标记
     */
    function mintPaid(address to, uint256 amount) external onlyAdmin {
        require(amount <= type(uint128).max, "B-Units: Amount exceeds uint128");
        _fuelBalances[to].paidPool += uint128(amount);
        _totalSupply += amount;
        _recordMint(amount);
        emit MintPaid(to, amount);
        emit Transfer(address(0), to, amount);
    }

    /**
     * @dev 针对商户大宗折扣的组合铸币 (如 CashTree 买一赠一)
     */
    function mintCombo(address to, uint256 paidAmount, uint256 rewardAmount) external onlyAdmin {
        require(paidAmount <= type(uint128).max && rewardAmount <= type(uint128).max, "B-Units: Amount overflow");
        
        if (paidAmount > 0) {
            _fuelBalances[to].paidPool += uint128(paidAmount);
            emit MintPaid(to, paidAmount);
        }
        if (rewardAmount > 0) {
            _fuelBalances[to].freePool += uint128(rewardAmount);
            emit MintReward(to, rewardAmount);
        }
        uint256 total = paidAmount + rewardAmount;
        _totalSupply += total;
        _recordMint(total);
        emit Transfer(address(0), to, total);
    }

    // ==========================================
    // 核心引擎：瀑布流核销与分润触发 (The Waterfall Burn)
    // ==========================================

    /**
     * @dev 业务网关扣除燃料专用接口，执行优先消耗 Free Pool 逻辑
     * @param user 被扣费用户
     * @param amount 扣减总金额 (需包含 6 位精度, 例: 2 Units 传入 2000000)
     */
    function consumeFuel(address user, uint256 amount) external onlyAdmin {
        FuelBalance storage bal = _fuelBalances[user];
        uint256 totalBal = uint256(bal.freePool) + uint256(bal.paidPool);
        require(totalBal >= amount, "B-Units: Insufficient balance");

        uint256 paidBurned = 0; // 记录真实燃烧的“付费DNA”燃料
        uint256 freeBurned = 0;

        // 瀑布流逻辑：优先抽干免费池
        if (bal.freePool >= amount) {
            // 免费池充足，全部由营销补贴吸收，不触发分润
            freeBurned = amount;
            bal.freePool -= uint128(amount);
        } else {
            // 免费池不足，抽干免费池后，剩余部分由付费池扣除
            freeBurned = uint256(bal.freePool);
            uint256 remaining = amount - freeBurned;
            bal.freePool = 0;
            bal.paidPool -= uint128(remaining);
            paidBurned = remaining; // 记录付费池的燃烧量
        }

        totalFreeBurned += freeBurned;
        totalPaidBurned += paidBurned;
        _totalSupply -= amount;
        _recordBurn(amount);

        // --- 节点分润计算核心 (Real Yield) ---
        if (paidBurned > 0) {
            // 分红公式：消耗付费燃料量的 5%
            // 由于精度为 6 位，即便是微小的消耗（例如 2000000 * 5 / 100 = 100000）也不会被截断归零
            uint256 yieldAmount = (paidBurned * 5) / 100;
            
            // 抛出链上跨链事件。去中心化预言机 (Relayer) 会监听此事件，
            // 并据此在 Base L2 Treasury 中释放对应的 USDC 法币给节点
            emit NodeYieldGenerated(user, paidBurned, yieldAmount);
        }

        emit FuelConsumed(user, amount);
        emit Transfer(user, address(0), amount);
    }

    // ==========================================
    // 周期统计报告 (offset n = 本周期 - n)
    // ==========================================

    /**
     * @dev 本小时 - n 小时的 mint/burn 统计。n=0 为当前小时。UTC 整点。
     */
    function getHourlyReport(uint256 n) external view returns (uint256 mint, uint256 burn) {
        uint256 slot = block.timestamp / HOUR;
        if (n > slot) return (0, 0);
        PeriodStats storage s = _hourlyStats[slot - n];
        return (s.mint, s.burn);
    }

    /**
     * @dev 本日 - n 日的 mint/burn 统计。n=0 为今日。UTC 0:00。
     */
    function getDailyReport(uint256 n) external view returns (uint256 mint, uint256 burn) {
        uint256 slot = block.timestamp / DAY;
        if (n > slot) return (0, 0);
        PeriodStats storage s = _dailyStats[slot - n];
        return (s.mint, s.burn);
    }

    /**
     * @dev 本周 - n 周的 mint/burn 统计。n=0 为本周。周一 0:00 UTC 起。
     */
    function getWeeklyReport(uint256 n) external view returns (uint256 mint, uint256 burn) {
        uint256 slot = (block.timestamp + WEEK_OFFSET) / WEEK;
        if (n > slot) return (0, 0);
        PeriodStats storage s = _weeklyStats[slot - n];
        return (s.mint, s.burn);
    }

    /**
     * @dev 本月 - n 月的 mint/burn 统计。n=0 为本月。自然月，1 日 0:00 UTC。
     */
    function getMonthlyReport(uint256 n) external view returns (uint256 mint, uint256 burn) {
        uint256 slot = _getMonthSlot(block.timestamp);
        if (n > slot) return (0, 0);
        PeriodStats storage s = _monthlyStats[slot - n];
        return (s.mint, s.burn);
    }

    /**
     * @dev 本季度 - n 季度的 mint/burn 统计。n=0 为本季度。1/4/7/10 月 1 日 0:00 UTC。
     */
    function getQuarterlyReport(uint256 n) external view returns (uint256 mint, uint256 burn) {
        uint256 slot = _getQuarterSlot(block.timestamp);
        if (n > slot) return (0, 0);
        PeriodStats storage s = _quarterlyStats[slot - n];
        return (s.mint, s.burn);
    }

    /**
     * @dev 本年 - n 年的 mint/burn 统计。n=0 为本年。自然年，1 月 1 日 0:00 UTC。
     */
    function getYearlyReport(uint256 n) external view returns (uint256 mint, uint256 burn) {
        uint256 slot = _getYearSlot(block.timestamp);
        if (n > slot) return (0, 0);
        PeriodStats storage s = _yearlyStats[slot - n];
        return (s.mint, s.burn);
    }
}

