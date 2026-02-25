// SPDX-License-Identifier: MIT
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
        
        emit MintReward(to, amount);
        emit Transfer(address(0), to, amount); // 触发标准事件适配浏览器
    }

    /**
     * @dev 铸造法币兑换 (付费池) - 带有分润染色标记
     */
    function mintPaid(address to, uint256 amount) external onlyAdmin {
        require(amount <= type(uint128).max, "B-Units: Amount exceeds uint128");
        _fuelBalances[to].paidPool += uint128(amount);
        _totalSupply += amount;

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

        // 瀑布流逻辑：优先抽干免费池
        if (bal.freePool >= amount) {
            // 免费池充足，全部由营销补贴吸收，不触发分润
            bal.freePool -= uint128(amount);
        } else {
            // 免费池不足，抽干免费池后，剩余部分由付费池扣除
            uint256 remaining = amount - uint256(bal.freePool);
            bal.freePool = 0;
            bal.paidPool -= uint128(remaining);
            paidBurned = remaining; // 记录付费池的燃烧量
        }

        _totalSupply -= amount;

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
        emit Transfer(user, address(0), amount); // 燃烧销毁事件，标准地址为 0x0
    }
}

