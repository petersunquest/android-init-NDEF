[dotenv@17.3.1] injecting env (0) from .env -- tip: ⚙️  override existing env vars with { override: true }
// Sources flattened with hardhat v3.1.9 https://hardhat.org

// SPDX-License-Identifier: MIT

// File src/BeamioUserCard/BeamioCurrency.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Shared currency enum across UserCard / Oracle / Factory
///         Future currency additions should happen ONLY here.
library BeamioCurrency {
    enum CurrencyType { CAD, USD, JPY, CNY, USDC, HKD, EUR, SGD, TWD, ETH, BNB, SOLANA, BTC }

    uint8 internal constant CAD  = uint8(CurrencyType.CAD);
    uint8 internal constant USD  = uint8(CurrencyType.USD);
    uint8 internal constant JPY  = uint8(CurrencyType.JPY);
    uint8 internal constant CNY  = uint8(CurrencyType.CNY);
    uint8 internal constant USDC = uint8(CurrencyType.USDC);
    uint8 internal constant HKD  = uint8(CurrencyType.HKD);
    uint8 internal constant EUR  = uint8(CurrencyType.EUR);
    uint8 internal constant SGD  = uint8(CurrencyType.SGD);
    uint8 internal constant TWD  = uint8(CurrencyType.TWD);
    uint8 internal constant ETH  = uint8(CurrencyType.ETH);
    uint8 internal constant BNB  = uint8(CurrencyType.BNB);
    uint8 internal constant SOLANA = uint8(CurrencyType.SOLANA);
    uint8 internal constant BTC  = uint8(CurrencyType.BTC);
}


// File src/contracts/utils/Context.sol

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/Context.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}


// File src/contracts/access/Ownable.sol

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}


// File src/BeamioUserCard/BeamioOracle.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity ^0.8.20;


/// @notice 汇率预言机。禁止重新部署，仅使用已有链上地址；新环境请配置 EXISTING_ORACLE_ADDRESS 引用现有合约。
contract BeamioOracle is Ownable {
    error OracleError();
    error RateLimitExceeded();
    error ArrayLengthMismatch();

    uint256 private constant E18 = 1e18;

    struct Breaker {
        uint16 maxChangeBps;   // 0 => use defaultMaxRateChangeBps
        uint120 minRateE18;    // 0 => no floor
        uint120 maxRateE18;    // 0 => no cap
    }

    /// 设计：所有汇率均为「该货币 → USD」的 E18 精度。换算到 USDC 时由 QuoteHelper 先换成 USD 再按 USDC 对 USD 换算（故意设计）。
    mapping(uint8 => uint256) public rates;        // currencyId => 该货币对 USD 的汇率 (E18)
    mapping(uint8 => Breaker) public breakers;

    uint256 public defaultMaxRateChangeBps = 2000;

    event RateUpdated(uint8 indexed currency, uint256 oldRate, uint256 newRate);
    event BreakerUpdated(uint8 indexed currency, uint16 maxChangeBps, uint120 minRateE18, uint120 maxRateE18);
    event DefaultMaxChangeUpdated(uint256 oldBps, uint256 newBps);

    constructor() Ownable(msg.sender) {
        // 基准：所有货币均按「对 USD」报价；换算 USDC 时用 USD 与 USDC 汇率（设计如此）
        rates[BeamioCurrency.USD] = E18;
        rates[BeamioCurrency.USDC] = E18;
    }

    // ================= Admin Functions =================

    function setDefaultMaxRateChangeBps(uint256 bps) external onlyOwner {
        if (bps > 10000) revert RateLimitExceeded();
        emit DefaultMaxChangeUpdated(defaultMaxRateChangeBps, bps);
        defaultMaxRateChangeBps = bps;
    }

    function setBreaker(uint8 c, uint16 bps, uint120 minR, uint120 maxR) external onlyOwner {
        if (bps > 10000) revert RateLimitExceeded();
        if (maxR != 0 && minR != 0 && maxR < minR) revert RateLimitExceeded();
        breakers[c] = Breaker(bps, minR, maxR);
        emit BreakerUpdated(c, bps, minR, maxR);
    }

    // ================= Update Functions (The Fix) =================

    /**
     * @notice 批量更新汇率，一次写入所有喂料
     * @param cs 货币 ID 数组
     * @param rs 对应的汇率数组 (E18 精度)
     */
    function updateRatesBatch(uint8[] calldata cs, uint256[] calldata rs) external onlyOwner {
        if (cs.length != rs.length) revert ArrayLengthMismatch();
        
        for (uint256 i = 0; i < cs.length; i++) {
            _setRate(cs[i], rs[i]);
        }
    }

    /**
     * @notice 单个更新汇率
     */
    function updateRate(uint8 c, uint256 rateE18) external onlyOwner {
        _setRate(c, rateE18);
    }

    /**
     * @dev 核心逻辑抽取，包含波动率和硬上限检查
     */
    function _setRate(uint8 c, uint256 rateE18) private {
        if (rateE18 == 0) revert OracleError();

        // 保护：USD 必须是 1.0 (ID: 1)
        if (c == BeamioCurrency.USD && rateE18 != E18) revert OracleError();

        Breaker memory b = breakers[c];

        // 硬性上下限检查 (minRateE18 / maxRateE18)
        if ((b.minRateE18 != 0 && rateE18 < b.minRateE18) || (b.maxRateE18 != 0 && rateE18 > b.maxRateE18)) {
            revert RateLimitExceeded();
        }

        uint256 old = rates[c];

        // 波动率检查 (maxChangeBps)
        if (old != 0) {
            uint256 maxBps = b.maxChangeBps == 0 ? defaultMaxRateChangeBps : b.maxChangeBps;
            uint256 lower = (old * (10000 - maxBps)) / 10000;
            uint256 upper = (old * (10000 + maxBps)) / 10000;
            if (rateE18 < lower || rateE18 > upper) revert RateLimitExceeded();
        }

        rates[c] = rateE18;
        emit RateUpdated(c, old, rateE18);
    }

    function getRate(uint8 c) external view returns (uint256) {
        uint256 r = rates[c];
        if (r == 0) revert OracleError();
        return r;
    }
}

