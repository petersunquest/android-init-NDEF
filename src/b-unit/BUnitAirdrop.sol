// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "../contracts/access/Ownable.sol";
import {IERC20} from "../contracts/token/ERC20/IERC20.sol";
import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BUnitAirdrop
 * @dev 管理 B-Units 空投，每个钱包仅可申领一次 20 BUint（免费池）。
 *      支持：1) 用户自领 claim()  2) 离线签字 + 代理提交 claimFor() 代付 gas。
 *      本合约需为 BeamioBUnits admin，以便 claim 时调用 mintReward。
 *      提供 B-Units 余额与 BeamioUserCard 资产查询接口。
 */

interface IBeamioIndexerDiamond {
    function getBeamioUserCardTokenIndexedBalance(address beamioUserCard, uint256 tokenId, address account) external view returns (uint256);
    function getAllCardsCount() external view returns (uint256);
    function getAllCardsPaged(uint256 offset, uint256 limit) external view returns (address[] memory);
}

/// @dev BeamioIndexerDiamond ActionFacet：claim 成功后记账
interface IActionFacet {
    struct RouteItemInput {
        address asset;
        uint256 amountE6;
        uint8 assetType;
        uint8 source;
        uint256 tokenId;
        uint8 itemCurrencyType;
        uint256 offsetInRequestCurrencyE6;
    }
    struct FeeInfoInput {
        uint16 gasChainType;
        uint256 gasWei;
        uint256 gasUSDC6;
        uint256 serviceUSDC6;
        uint256 bServiceUSDC6;
        uint256 bServiceUnits6;
        address feePayer;
    }
    struct TransactionMetaInput {
        uint256 requestAmountFiat6;
        uint256 requestAmountUSDC6;
        uint8 currencyFiat;
        uint256 discountAmountFiat6;
        uint16 discountRateBps;
        uint256 taxAmountFiat6;
        uint16 taxRateBps;
        string afterNotePayer;
        string afterNotePayee;
    }
    struct TransactionInput {
        bytes32 txId;
        bytes32 originalPaymentHash;
        uint256 chainId;
        bytes32 txCategory;
        string displayJson;
        uint64 timestamp;
        address payer;
        address payee;
        uint256 finalRequestAmountFiat6;
        uint256 finalRequestAmountUSDC6;
        bool isAAAccount;
        RouteItemInput[] route;
        FeeInfoInput fees;
        TransactionMetaInput meta;
        address operator;
        address[] operatorParentChain;
    }
    function syncTokenAction(TransactionInput calldata in_) external returns (uint256 actionId);
}

interface IBeamioBUnits {
    function totalFreeBurned() external view returns (uint256);
    function totalPaidBurned() external view returns (uint256);
    function consumeFuel(address user, uint256 amount) external returns (uint256 paidBurned);
    function getHourlyReport(uint256 n) external view returns (uint256 mint, uint256 burn);
    function getDailyReport(uint256 n) external view returns (uint256 mint, uint256 burn);
    function getWeeklyReport(uint256 n) external view returns (uint256 mint, uint256 burn);
    function getMonthlyReport(uint256 n) external view returns (uint256 mint, uint256 burn);
    function getQuarterlyReport(uint256 n) external view returns (uint256 mint, uint256 burn);
    function getYearlyReport(uint256 n) external view returns (uint256 mint, uint256 burn);
}

interface IConetTreasury {
    function mintForAdmin(address token, address recipient, uint256 amount) external;
}

/// @dev BeamioQuoteHelperV07：ETH(wei) 经 oracle 换算为 USDC6
interface IBeamioQuoteHelper {
    function quoteCurrencyAmountInUSDC6(uint8 cur, uint256 amount6) external view returns (uint256);
}

struct CardBalance {
    address card;
    uint256 tokenId;
    uint256 balanceE6;
}

/// @dev B-Units 综合统计报告：空投 + 焚烧 (6 位精度)
struct BUnitReport {
    uint256 freeAirdropped;
    uint256 paidAirdropped;
    uint256 totalAirdropped;
    uint256 freeBurned;
    uint256 paidBurned;
    uint256 totalBurned;
}

// ==========================================
// 窗口期返回数据结构 (Period Window Report)
// ==========================================

/// @dev 内部存储用：周期事件统计（空投次数、焚烧次数、gas 累计）
struct PeriodEventStats {
    uint256 airdropCount;
    uint256 burnCount;
    uint256 gas;
    uint256 gasUSDC;   // Base 链 gas 换算为 USDC 累计 (6 decimals)
}

/// @dev 窗口期汇总：BUnitAirdrop 事件统计 + BeamioBUnits mint/burn + kind 分类焚烧明细
///      由 get*Report(n) / get*ReportFull(n, kinds) 返回，n=0 为当前周期
struct PeriodSummary {
    uint256 airdropCount;   // 空投次数
    uint256 burnCount;      // 焚烧次数
    uint256 gas;            // Base 链 gas 累计
    uint256 gasUSDC;        // Base 链 gas 换算为 USDC 累计 (6 decimals)
    uint256 bunitMint;      // BeamioBUnits 该周期 mint 量 (6 decimals)
    uint256 bunitBurn;      // BeamioBUnits 该周期 burn 量 (6 decimals)
    KindBurnDetail[] kindBurns;  // kind 分类焚烧明细
}

/// @dev 窗口期内按 kind 分类的焚烧明细
///      由 get*KindBurns(n, kinds) 返回
struct KindBurnDetail {
    uint256 kind;      // 分类标识
    uint256 amount;    // 焚烧量 (6 decimals)
    uint256 count;     // 焚烧次数
    uint256 gas;       // Base 链 gas 累计
    uint256 gasUSDC;   // Base 链 gas 换算为 USDC 累计 (6 decimals)
}

/// @dev 窗口期完整报告：get*ReportFull(n, kinds) 一次返回 (PeriodSummary summary, KindBurnDetail[] kindBurns)

contract BUnitAirdrop is Ownable, EIP712 {
    /// @dev 当前 CoNET mainnet 上部署的 BeamioIndexerDiamond 地址（硬编码默认值）
    address private constant DEFAULT_BEAMIO_INDEXER = 0x0DBDF27E71f9c89353bC5e4dC27c9C5dAe0cc612;
    /// @dev CoNET 主网 chainId（claim 记账用）
    uint256 private constant CONET_CHAIN_ID = 224400;
    /// @dev claim 记账 txCategory
    bytes32 private constant TX_BUINT_CLAIM = keccak256("buintClaim");
    /// @dev USDC 购买 B-Unit 记账 txCategory
    bytes32 private constant TX_BUINT_USDC = keccak256("buintUSDC");
    /// @dev CoNET 上 BeamioQuoteHelperV07 地址，用于 baseGas(wei) → USDC6 换算
    address private constant DEFAULT_QUOTE_HELPER = 0x07B514aDdE61C07B8b338C16444F662Fa6Fb1953;
    /// @dev Oracle 中 ETH 的 currency id（BeamioCurrency 扩展）
    uint8 private constant ETH_CURRENCY = 9;

    IERC20 public immutable bunit;

    /// @dev BeamioIndexerDiamond 地址，用于查询 BeamioUserCard 资产。Admin 可更改。
    address public beamioIndexerDiamond;
    /// @dev BeamioQuoteHelperV07 地址，用于 baseGas → gasUSDC 换算。Owner 可更改。
    address public quoteHelper;

    /// @dev 固定空投数量：20 BUint (6 decimals)。Owner 可修改。
    uint256 public claimAmount;
    /// @dev 焚烧 1 BUint = 0.01 USDC，即 amount / 100
    uint256 public constant BUNIT_TO_USDC_RATE = 100;
    /// @dev USDC 购买 B-Unit 汇率：1 USDC (6 decimals) = 100 B-Units (6 decimals)
    uint256 public constant USDC_TO_BUNIT_RATE = 100;

    /// @dev ConetTreasury 与 CoNET USDC，用于 consumeFromUser 后 airdrop USDC 到本合约
    address public conetTreasury;
    address public conetUsdc;

    mapping(address => bool) public admins;
    mapping(address => bool) public hasClaimed;   // 是否已申领（一人一次）
    mapping(address => uint256) public claimNonces;  // 离线签字 replay 防护

    /// @dev 空投统计：免费池与付费池各自的累计空投量 (6 位精度)
    uint256 public totalFreeAirdropped;
    uint256 public totalPaidAirdropped;

    /// @dev 事件件数统计
    uint256 public airdropCount;     // 空投件数（claim/claimFor/mintForUsdcPurchase 各计 1）
    uint256 public burnCount;       // 焚烧件数（consumeFromUser 每次计 1）
    uint256 public totalBaseGas;    // Base 链 gas 累计（consumeFromUser 的 baseGas 累加）
    uint256 public totalBaseGasUSDC; // Base 链 gas 换算为 USDC 累计 (6 decimals)

    /// @dev 周期事件统计（空投次数、焚烧次数、gas 累计），统一 UTC 自然时间
    uint256 private constant HOUR = 3600;
    uint256 private constant DAY = 86400;
    uint256 private constant WEEK = 604800;
    uint256 private constant WEEK_OFFSET = 345600;  // Jan 1 1970 周四，周一 0:00 UTC
    mapping(uint256 => PeriodEventStats) private _hourlyEventStats;
    mapping(uint256 => PeriodEventStats) private _dailyEventStats;
    mapping(uint256 => PeriodEventStats) private _weeklyEventStats;
    mapping(uint256 => PeriodEventStats) private _monthlyEventStats;
    mapping(uint256 => PeriodEventStats) private _quarterlyEventStats;
    mapping(uint256 => PeriodEventStats) private _yearlyEventStats;

    /// @dev 窗口期内按 kind 分类的焚烧明细：slot => kind => (amount, count, gas)
    mapping(uint256 => mapping(uint256 => uint256)) private _hourlyKindAmount;
    mapping(uint256 => mapping(uint256 => uint256)) private _hourlyKindCount;
    mapping(uint256 => mapping(uint256 => uint256)) private _hourlyKindGas;
    mapping(uint256 => mapping(uint256 => uint256)) private _dailyKindAmount;
    mapping(uint256 => mapping(uint256 => uint256)) private _dailyKindCount;
    mapping(uint256 => mapping(uint256 => uint256)) private _dailyKindGas;
    mapping(uint256 => mapping(uint256 => uint256)) private _weeklyKindAmount;
    mapping(uint256 => mapping(uint256 => uint256)) private _weeklyKindCount;
    mapping(uint256 => mapping(uint256 => uint256)) private _weeklyKindGas;
    mapping(uint256 => mapping(uint256 => uint256)) private _monthlyKindAmount;
    mapping(uint256 => mapping(uint256 => uint256)) private _monthlyKindCount;
    mapping(uint256 => mapping(uint256 => uint256)) private _monthlyKindGas;
    mapping(uint256 => mapping(uint256 => uint256)) private _quarterlyKindAmount;
    mapping(uint256 => mapping(uint256 => uint256)) private _quarterlyKindCount;
    mapping(uint256 => mapping(uint256 => uint256)) private _quarterlyKindGas;
    mapping(uint256 => mapping(uint256 => uint256)) private _yearlyKindAmount;
    mapping(uint256 => mapping(uint256 => uint256)) private _yearlyKindCount;
    mapping(uint256 => mapping(uint256 => uint256)) private _yearlyKindGas;
    mapping(uint256 => mapping(uint256 => uint256)) private _yearlyKindGasUsdc;

    mapping(uint256 => mapping(uint256 => uint256)) private _hourlyKindGasUsdc;
    mapping(uint256 => mapping(uint256 => uint256)) private _dailyKindGasUsdc;
    mapping(uint256 => mapping(uint256 => uint256)) private _weeklyKindGasUsdc;
    mapping(uint256 => mapping(uint256 => uint256)) private _monthlyKindGasUsdc;
    mapping(uint256 => mapping(uint256 => uint256)) private _quarterlyKindGasUsdc;

    /// @dev 不分窗口期的累积 kind 焚烧明细：kind => (amount, count, gas, gasUSDC)
    mapping(uint256 => uint256) private _cumulativeKindAmount;
    mapping(uint256 => uint256) private _cumulativeKindCount;
    mapping(uint256 => uint256) private _cumulativeKindGas;
    mapping(uint256 => uint256) private _cumulativeKindGasUsdc;

    /// @dev kind 登记：kind => 名称字符串
    mapping(uint256 => string) private _kindNames;
    mapping(uint256 => bool) private _kindRegistered;
    uint256[] private _kindList;

    bytes32 private constant CLAIM_TYPEHASH =
        keccak256("ClaimAirdrop(address claimant,uint256 nonce,uint256 deadline)");

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event BeamioIndexerDiamondUpdated(address indexed oldIndexer, address indexed newIndexer);
    event Claimed(address indexed account, uint256 amount);
    event ClaimedFor(address indexed account, uint256 amount, address indexed relayer);
    event ConsumedAndAirdropped(
        address indexed user,
        uint256 bunitBurned,
        uint256 usdcAirdropped,
        bytes32 baseHash,
        uint256 baseGas,
        uint256 kind
    );
    event WithdrewUsdc(address indexed to, uint256 amount);
    event ConetTreasuryAndUsdcUpdated(address indexed conetTreasury, address indexed conetUsdc);
    event KindRegistered(uint256 indexed kind, string name);
    event QuoteHelperUpdated(address indexed oldHelper, address indexed newHelper);
    event ClaimAmountUpdated(uint256 indexed oldAmount, uint256 indexed newAmount);
    /// @dev syncTokenAction 失败时发出，便于排查 Indexer 未记账问题
    event IndexerSyncFailed(bytes32 indexed context, string reason);

    modifier onlyAdmin() {
        if (msg.sender != owner() && !admins[msg.sender]) revert Unauthorized();
        _;
    }

    error Unauthorized();
    error ClaimNotAvailable();
    error TransferFailed();
    error InvalidSignature();
    error SignatureExpired();
    error InvalidConfig();

    constructor(address _bunit, address initialOwner) Ownable(initialOwner) EIP712("BUnitAirdrop", "1") {
        bunit = IERC20(_bunit);
        claimAmount = 20 * 1e6;
        beamioIndexerDiamond = DEFAULT_BEAMIO_INDEXER;
        quoteHelper = DEFAULT_QUOTE_HELPER;
    }

    /**
     * @dev Owner 修改免费池单次申领数量 (6 decimals)。
     */
    function setClaimAmount(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert InvalidConfig();
        uint256 old = claimAmount;
        claimAmount = _amount;
        emit ClaimAmountUpdated(old, _amount);
    }

    function _getMonthSlot(uint256 timestamp) internal pure returns (uint256) {
        uint256 d = timestamp / DAY;
        uint256 y = 1970;
        for (;;) {
            uint256 daysInYear = ((y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)) ? 366 : 365;
            if (d < daysInYear) break;
            d -= daysInYear;
            y++;
        }
        uint256 month = 0;
        uint256[12] memory dims;
        dims[0] = 31; dims[1] = ((y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)) ? 29 : 28;
        dims[2] = 31; dims[3] = 30; dims[4] = 31; dims[5] = 30; dims[6] = 31; dims[7] = 31;
        dims[8] = 30; dims[9] = 31; dims[10] = 30; dims[11] = 31;
        for (uint256 m = 0; m < 12; m++) {
            if (d < dims[m]) break;
            d -= dims[m];
            month++;
        }
        return (y - 1970) * 12 + month;
    }

    function _getQuarterSlot(uint256 timestamp) internal pure returns (uint256) {
        return _getMonthSlot(timestamp) / 3;
    }

    function _getYearSlot(uint256 timestamp) internal pure returns (uint256) {
        uint256 d = timestamp / DAY;
        uint256 y = 1970;
        for (;;) {
            uint256 daysInYear = ((y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)) ? 366 : 365;
            if (d < daysInYear) break;
            d -= daysInYear;
            y++;
        }
        return y - 1970;
    }

    function _recordAirdrop() internal {
        uint256 ts = block.timestamp;
        _hourlyEventStats[ts / HOUR].airdropCount++;
        _dailyEventStats[ts / DAY].airdropCount++;
        _weeklyEventStats[(ts + WEEK_OFFSET) / WEEK].airdropCount++;
        _monthlyEventStats[_getMonthSlot(ts)].airdropCount++;
        _quarterlyEventStats[_getQuarterSlot(ts)].airdropCount++;
        _yearlyEventStats[_getYearSlot(ts)].airdropCount++;
    }

    function _recordBurn(uint256 baseGas, uint256 gasUSDC, uint256 amount, uint256 kind) internal {
        uint256 ts = block.timestamp;
        uint256 hSlot = ts / HOUR;
        uint256 dSlot = ts / DAY;
        uint256 wSlot = (ts + WEEK_OFFSET) / WEEK;
        uint256 mSlot = _getMonthSlot(ts);
        uint256 qSlot = _getQuarterSlot(ts);
        uint256 ySlot = _getYearSlot(ts);

        _hourlyEventStats[hSlot].burnCount++;
        _hourlyEventStats[hSlot].gas += baseGas;
        _hourlyEventStats[hSlot].gasUSDC += gasUSDC;
        _hourlyKindAmount[hSlot][kind] += amount;
        _hourlyKindCount[hSlot][kind]++;
        _hourlyKindGas[hSlot][kind] += baseGas;
        _hourlyKindGasUsdc[hSlot][kind] += gasUSDC;

        _dailyEventStats[dSlot].burnCount++;
        _dailyEventStats[dSlot].gas += baseGas;
        _dailyEventStats[dSlot].gasUSDC += gasUSDC;
        _dailyKindAmount[dSlot][kind] += amount;
        _dailyKindCount[dSlot][kind]++;
        _dailyKindGas[dSlot][kind] += baseGas;
        _dailyKindGasUsdc[dSlot][kind] += gasUSDC;

        _weeklyEventStats[wSlot].burnCount++;
        _weeklyEventStats[wSlot].gas += baseGas;
        _weeklyEventStats[wSlot].gasUSDC += gasUSDC;
        _weeklyKindAmount[wSlot][kind] += amount;
        _weeklyKindCount[wSlot][kind]++;
        _weeklyKindGas[wSlot][kind] += baseGas;
        _weeklyKindGasUsdc[wSlot][kind] += gasUSDC;

        _monthlyEventStats[mSlot].burnCount++;
        _monthlyEventStats[mSlot].gas += baseGas;
        _monthlyEventStats[mSlot].gasUSDC += gasUSDC;
        _monthlyKindAmount[mSlot][kind] += amount;
        _monthlyKindCount[mSlot][kind]++;
        _monthlyKindGas[mSlot][kind] += baseGas;
        _monthlyKindGasUsdc[mSlot][kind] += gasUSDC;

        _quarterlyEventStats[qSlot].burnCount++;
        _quarterlyEventStats[qSlot].gas += baseGas;
        _quarterlyEventStats[qSlot].gasUSDC += gasUSDC;
        _quarterlyKindAmount[qSlot][kind] += amount;
        _quarterlyKindCount[qSlot][kind]++;
        _quarterlyKindGas[qSlot][kind] += baseGas;
        _quarterlyKindGasUsdc[qSlot][kind] += gasUSDC;

        _yearlyEventStats[ySlot].burnCount++;
        _yearlyEventStats[ySlot].gas += baseGas;
        _yearlyEventStats[ySlot].gasUSDC += gasUSDC;
        _yearlyKindAmount[ySlot][kind] += amount;
        _yearlyKindCount[ySlot][kind]++;
        _yearlyKindGas[ySlot][kind] += baseGas;
        _yearlyKindGasUsdc[ySlot][kind] += gasUSDC;

        _cumulativeKindAmount[kind] += amount;
        _cumulativeKindCount[kind] += 1;
        _cumulativeKindGas[kind] += baseGas;
        _cumulativeKindGasUsdc[kind] += gasUSDC;
    }

    /**
     * @dev Admin 更新 BeamioIndexerDiamond 地址。
     */
    function setBeamioIndexerDiamond(address _indexer) external onlyAdmin {
        address oldIndexer = beamioIndexerDiamond;
        beamioIndexerDiamond = _indexer;
        emit BeamioIndexerDiamondUpdated(oldIndexer, _indexer);
    }

    /**
     * @dev 添加 admin。
     */
    function addAdmin(address account) external onlyOwner {
        if (account == address(0)) revert Unauthorized();
        admins[account] = true;
        emit AdminAdded(account);
    }

    /**
     * @dev 移除 admin。
     */
    function removeAdmin(address account) external onlyOwner {
        admins[account] = false;
        emit AdminRemoved(account);
    }

    /**
     * @dev 返回 claimFor 的 EIP-712 摘要，供前端 signTypedData 后传给 claimFor。
     *      domain: { name: "BUnitAirdrop", version: "1", chainId, verifyingContract }
     *      types: { ClaimAirdrop: [{ name: "claimant", type: "address" }, { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" }] }
     */
    function getClaimDigest(address claimant, uint256 nonce, uint256 deadline) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, claimant, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    /**
     * @dev 申领 20 BUint（免费池）。每账号仅可申领一次，用户自付 gas。
     */
    function claim() external {
        _doClaim(msg.sender);
        emit Claimed(msg.sender, claimAmount);
    }

    /**
     * @dev 离线签字代领。用户离线签 ClaimAirdrop(claimant, nonce, deadline)，
     *      代理（如 admin）调用此函数并代付 gas，BUint 转至 claimant。
     *      signature 为 65 字节 (r,s,v)。
     */
    function claimFor(
        address claimant,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (claimNonces[claimant] != nonce) revert InvalidSignature();

        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, claimant, nonce, deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != claimant) revert InvalidSignature();

        claimNonces[claimant]++;
        _doClaim(claimant);
        emit ClaimedFor(claimant, claimAmount, msg.sender);
    }

    /**
     * @dev 执行申领逻辑：校验未领过，mintReward（免费池）给 account。成功后向 BeamioIndexerDiamond 记账。
     */
    function _doClaim(address account) internal {
        if (hasClaimed[account]) revert ClaimNotAvailable();

        hasClaimed[account] = true;
        totalFreeAirdropped += claimAmount;
        airdropCount++;
        _recordAirdrop();

        (bool ok,) = address(bunit).call(
            abi.encodeWithSignature("mintReward(address,uint256)", account, claimAmount)
        );
        if (!ok) revert TransferFailed();

        _indexClaimToBeamioIndexer(account);
    }

    /**
     * @dev claim 成功后向 BeamioIndexerDiamond 记账。txCategory=buintClaim，payer=BUint，payee=claimant，route 为空。
     *      本合约需为 BeamioIndexerDiamond admin。失败不 revert，避免阻塞 claim。
     */
    function _indexClaimToBeamioIndexer(address account) internal {
        address idx = beamioIndexerDiamond != address(0) ? beamioIndexerDiamond : DEFAULT_BEAMIO_INDEXER;
        bytes32 txId = keccak256(abi.encodePacked(account, block.number, block.timestamp, block.prevrandao, address(this), "buintClaim"));
        IActionFacet.TransactionInput memory in_ = IActionFacet.TransactionInput({
            txId: txId,
            originalPaymentHash: bytes32(0),
            chainId: CONET_CHAIN_ID,
            txCategory: TX_BUINT_CLAIM,
            displayJson: "",
            timestamp: uint64(block.timestamp),
            payer: address(bunit),
            payee: account,
            finalRequestAmountFiat6: claimAmount,
            finalRequestAmountUSDC6: claimAmount,
            isAAAccount: false,
            route: new IActionFacet.RouteItemInput[](0),
            fees: IActionFacet.FeeInfoInput({
                gasChainType: 0,
                gasWei: 0,
                gasUSDC6: 0,
                serviceUSDC6: 0,
                bServiceUSDC6: 0,
                bServiceUnits6: 0,
                feePayer: address(0)
            }),
            meta: IActionFacet.TransactionMetaInput({
                requestAmountFiat6: claimAmount,
                requestAmountUSDC6: claimAmount,
                currencyFiat: 0,
                discountAmountFiat6: 0,
                discountRateBps: 0,
                taxAmountFiat6: 0,
                taxRateBps: 0,
                afterNotePayer: "",
                afterNotePayee: ""
            }),
            operator: address(0),
            operatorParentChain: new address[](0)
        });
        try IActionFacet(idx).syncTokenAction(in_) {} catch Error(string memory reason) {
            emit IndexerSyncFailed(TX_BUINT_CLAIM, reason);
        } catch (bytes memory) {
            emit IndexerSyncFailed(TX_BUINT_CLAIM, "syncTokenAction low-level revert");
        }
    }

    /**
     * @dev USDC 购买 B-Unit 成功后向 BeamioIndexerDiamond 记账。txCategory=buintUSDC，payer=BUint，payee=to，route 为空。
     *      usdcAmount=用户支付的 USDC，bunitAmount=铸造的 B-Units。
     *      baseTxHash=Base 链上 USDC 转账 tx hash，写入 originalPaymentHash 供前端关联；displayJson 仅存 Indexer 约定字段，不自行组装。
     */
    function _indexUsdcPurchaseToBeamioIndexer(address to, uint256 usdcAmount, uint256 bunitAmount, bytes32 baseTxHash) internal {
        address idx = beamioIndexerDiamond != address(0) ? beamioIndexerDiamond : DEFAULT_BEAMIO_INDEXER;
        bytes32 txId = keccak256(abi.encodePacked(to, block.number, block.timestamp, block.prevrandao, address(this), "buintUSDC"));
        // baseTxHash 写入 originalPaymentHash 供前端关联 Base 链 purchase tx
        IActionFacet.TransactionInput memory in_ = IActionFacet.TransactionInput({
            txId: txId,
            originalPaymentHash: baseTxHash,
            chainId: CONET_CHAIN_ID,
            txCategory: TX_BUINT_USDC,
            displayJson: "",
            timestamp: uint64(block.timestamp),
            payer: address(bunit),
            payee: to,
            finalRequestAmountFiat6: bunitAmount,
            finalRequestAmountUSDC6: usdcAmount,
            isAAAccount: false,
            route: new IActionFacet.RouteItemInput[](0),
            fees: IActionFacet.FeeInfoInput({
                gasChainType: 0,
                gasWei: 0,
                gasUSDC6: 0,
                serviceUSDC6: 0,
                bServiceUSDC6: 0,
                bServiceUnits6: 0,
                feePayer: address(0)
            }),
            meta: IActionFacet.TransactionMetaInput({
                requestAmountFiat6: bunitAmount,
                requestAmountUSDC6: usdcAmount,
                currencyFiat: 0,
                discountAmountFiat6: 0,
                discountRateBps: 0,
                taxAmountFiat6: 0,
                taxRateBps: 0,
                afterNotePayer: "",
                afterNotePayee: ""
            }),
            operator: address(0),
            operatorParentChain: new address[](0)
        });
        try IActionFacet(idx).syncTokenAction(in_) {} catch Error(string memory reason) {
            emit IndexerSyncFailed(TX_BUINT_USDC, reason);
        } catch (bytes memory) {
            emit IndexerSyncFailed(TX_BUINT_USDC, "syncTokenAction low-level revert");
        }
    }

    /**
     * @dev USDC 购买 B-Unit：仅 admin（ConetTreasury）可调用。入参为 usdcAmount (6 decimals)，
     *      按 USDC_TO_BUNIT_RATE (1 USDC = 100 B-Units) 计算 bunitAmount 后铸造到付费池。
     *      成功后向 BeamioIndexerDiamond 记账，txCategory=buintUSDC。
     *      baseTxHash=Base 链上 USDC 转账 tx hash，写入 originalPaymentHash 供前端关联。
     */
    function mintForUsdcPurchase(address to, uint256 usdcAmount, bytes32 baseTxHash) external onlyAdmin {
        if (to == address(0)) revert Unauthorized();
        if (usdcAmount == 0) revert ClaimNotAvailable();
        uint256 bunitAmount = usdcAmount * USDC_TO_BUNIT_RATE;
        totalPaidAirdropped += bunitAmount;
        airdropCount++;
        _recordAirdrop();
        (bool ok,) = address(bunit).call(
            abi.encodeWithSignature("mintPaid(address,uint256)", to, bunitAmount)
        );
        if (!ok) revert TransferFailed();

        _indexUsdcPurchaseToBeamioIndexer(to, usdcAmount, bunitAmount, baseTxHash);
    }

    /**
     * @dev 设置 ConetTreasury 与 CoNET USDC 地址，用于 consumeFromUser。
     */
    function setConetTreasuryAndUsdc(address _conetTreasury, address _conetUsdc) external onlyOwner {
        conetTreasury = _conetTreasury;
        conetUsdc = _conetUsdc;
        emit ConetTreasuryAndUsdcUpdated(_conetTreasury, _conetUsdc);
    }

    /**
     * @dev Owner 设置 BeamioQuoteHelperV07 地址，用于 baseGas(wei) → USDC6 换算。
     */
    function setQuoteHelper(address _quoteHelper) external onlyOwner {
        address old = quoteHelper;
        quoteHelper = _quoteHelper;
        emit QuoteHelperUpdated(old, _quoteHelper);
    }

    /**
     * @dev Admin 登记 kind 与名称的映射。已登记的 kind 可更新名称。
     */
    function registerKind(uint256 kind, string calldata name) external onlyAdmin {
        _kindNames[kind] = name;
        if (!_kindRegistered[kind]) {
            _kindRegistered[kind] = true;
            _kindList.push(kind);
        }
        emit KindRegistered(kind, name);
    }

    /**
     * @dev 返回 kind 对应的名称。
     */
    function getKindName(uint256 kind) external view returns (string memory) {
        return _kindNames[kind];
    }

    /**
     * @dev 返回所有已登记的 kind 数组。
     */
    function getAllKinds() external view returns (uint256[] memory) {
        return _kindList;
    }

    /**
     * @dev 返回所有已登记的 kind 及其名称。
     */
    function getAllKindsWithNames() external view returns (uint256[] memory kinds, string[] memory names) {
        uint256 len = _kindList.length;
        kinds = new uint256[](len);
        names = new string[](len);
        for (uint256 i = 0; i < len; i++) {
            kinds[i] = _kindList[i];
            names[i] = _kindNames[_kindList[i]];
        }
    }

    /**
     * @dev Admin 焚烧指定用户的 BUint。仅当焚烧来自付费池时，按 1 BUint = 0.01 USDC 将 USDC airdrop 到本合约。
     *      本合约需为 BUint admin（可调用 consumeFuel）且为 ConetTreasury admin（可调用 mintForAdmin）。
     * @param user 被焚烧 BUint 的用户（需有足够余额）
     * @param amount 焚烧数量 (6 decimals)
     * @param baseHash Base 链关联交易 hash
     * @param baseGas Base 链 gas 消耗
     * @param kind 分类标识
     */
    function consumeFromUser(
        address user,
        uint256 amount,
        bytes32 baseHash,
        uint256 baseGas,
        uint256 kind
    ) external onlyAdmin {
        if (conetTreasury == address(0) || conetUsdc == address(0)) revert InvalidConfig();
        if (amount == 0) revert ClaimNotAvailable();

        uint256 paidBurned = IBeamioBUnits(address(bunit)).consumeFuel(user, amount);

        uint256 usdcAmount = paidBurned / BUNIT_TO_USDC_RATE;
        if (usdcAmount > 0) {
            IConetTreasury(conetTreasury).mintForAdmin(conetUsdc, address(this), usdcAmount);
        }

        uint256 gasUSDC = 0;
        if (baseGas > 0 && quoteHelper != address(0)) {
            try IBeamioQuoteHelper(quoteHelper).quoteCurrencyAmountInUSDC6(ETH_CURRENCY, baseGas / 1e12) returns (uint256 v) {
                gasUSDC = v;
            } catch {}
        }

        burnCount++;
        totalBaseGas += baseGas;
        totalBaseGasUSDC += gasUSDC;
        _recordBurn(baseGas, gasUSDC, amount, kind);
        emit ConsumedAndAirdropped(user, amount, usdcAmount, baseHash, baseGas, kind);

        _indexBurnToBeamioIndexer(user, amount, paidBurned, baseHash, baseGas, gasUSDC, kind);
    }

    /**
     * @dev 焚烧成功后向 BeamioIndexerDiamond 记账。txCategory=keccak256(kind 对应 string)，
     *      finalRequestAmountFiat6=焚烧总额，finalRequestAmountUSDC6=焚烧付费池 BUint。
     *      baseHash 非零时写入 displayJson 供前端展示 Base 链关联交易。
     */
    function _indexBurnToBeamioIndexer(
        address user,
        uint256 amount,
        uint256 paidBurned,
        bytes32 baseHash,
        uint256 baseGas,
        uint256 gasUSDC,
        uint256 kind
    ) internal {
        address idx = beamioIndexerDiamond != address(0) ? beamioIndexerDiamond : DEFAULT_BEAMIO_INDEXER;
        string memory kindName = _kindNames[kind];
        bytes32 txCategory = bytes(kindName).length > 0
            ? keccak256(abi.encodePacked(kindName))
            : keccak256("buintBurn");
        bytes32 txId = keccak256(abi.encodePacked(user, block.number, block.timestamp, block.prevrandao, address(this), "buintBurn", kind));
        // baseHash 写入 originalPaymentHash 供前端关联 Base 链关联交易
        IActionFacet.TransactionInput memory in_ = IActionFacet.TransactionInput({
            txId: txId,
            originalPaymentHash: baseHash,
            chainId: CONET_CHAIN_ID,
            txCategory: txCategory,
            displayJson: "",
            timestamp: uint64(block.timestamp),
            payer: user,
            payee: address(bunit),
            finalRequestAmountFiat6: amount,
            finalRequestAmountUSDC6: paidBurned,
            isAAAccount: false,
            route: new IActionFacet.RouteItemInput[](0),
            fees: IActionFacet.FeeInfoInput({
                gasChainType: 0,
                gasWei: baseGas,
                gasUSDC6: gasUSDC,
                serviceUSDC6: 0,
                bServiceUSDC6: 0,
                bServiceUnits6: 0,
                feePayer: user
            }),
            meta: IActionFacet.TransactionMetaInput({
                requestAmountFiat6: amount,
                requestAmountUSDC6: paidBurned,
                currencyFiat: 0,
                discountAmountFiat6: 0,
                discountRateBps: 0,
                taxAmountFiat6: 0,
                taxRateBps: 0,
                afterNotePayer: "",
                afterNotePayee: ""
            }),
            operator: address(0),
            operatorParentChain: new address[](0)
        });
        try IActionFacet(idx).syncTokenAction(in_) {} catch Error(string memory reason) {
            emit IndexerSyncFailed(txCategory, reason);
        } catch (bytes memory) {
            emit IndexerSyncFailed(txCategory, "syncTokenAction low-level revert");
        }
    }

    /**
     * @dev Admin 提取本合约持有的 CoNET USDC。
     */
    function withdrawUsdc(address to, uint256 amount) external onlyAdmin {
        if (to == address(0) || amount == 0) revert ClaimNotAvailable();
        require(conetUsdc != address(0), "USDC not set");
        require(IERC20(conetUsdc).transfer(to, amount), "BUnitAirdrop: USDC transfer failed");
        emit WithdrewUsdc(to, amount);
    }

    // ==========================================
    // 查询接口
    // ==========================================

    /**
     * @dev 返回事件件数统计：空投件数、焚烧件数、Base 链 gas 累计、gas 换算 USDC 累计。
     */
    function getEventStats() external view returns (uint256 _airdropCount, uint256 _burnCount, uint256 _totalBaseGas, uint256 _totalBaseGasUSDC) {
        return (airdropCount, burnCount, totalBaseGas, totalBaseGasUSDC);
    }

    // ==========================================
    // 不分窗口期的累积统计报告
    // ==========================================

    /**
     * @dev 返回全量累积统计：与 PeriodSummary 结构一致，bunitMint/bunitBurn 为 BeamioBUnits 历史总量。
     */
    function getCumulativeReport() external view returns (PeriodSummary memory report) {
        IBeamioBUnits bu = IBeamioBUnits(address(bunit));
        uint256 totalBurned = bu.totalFreeBurned() + bu.totalPaidBurned();
        uint256 totalMinted = bunit.totalSupply() + totalBurned;
        return PeriodSummary({
            airdropCount: airdropCount,
            burnCount: burnCount,
            gas: totalBaseGas,
            gasUSDC: totalBaseGasUSDC,
            bunitMint: totalMinted,
            bunitBurn: totalBurned,
            kindBurns: _getCumulativeKindBurns(_getKindList())
        });
    }

    /**
     * @dev 返回全量累积统计 + 指定 kinds 的焚烧明细，一次返回。
     */
    function getCumulativeReportFull(uint256[] calldata kinds) external view returns (PeriodSummary memory summary, KindBurnDetail[] memory kindBurns) {
        IBeamioBUnits bu = IBeamioBUnits(address(bunit));
        uint256 totalBurned = bu.totalFreeBurned() + bu.totalPaidBurned();
        uint256 totalMinted = bunit.totalSupply() + totalBurned;
        kindBurns = _getCumulativeKindBurns(kinds);
        summary = PeriodSummary({
            airdropCount: airdropCount,
            burnCount: burnCount,
            gas: totalBaseGas,
            gasUSDC: totalBaseGasUSDC,
            bunitMint: totalMinted,
            bunitBurn: totalBurned,
            kindBurns: kindBurns
        });
    }

    /**
     * @dev 全量累积下各 kind 的焚烧明细。kinds 为要查询的分类数组。
     */
    function getCumulativeKindBurns(uint256[] calldata kinds) external view returns (KindBurnDetail[] memory details) {
        return _getCumulativeKindBurns(kinds);
    }

    function _getCumulativeKindBurns(uint256[] memory kinds) private view returns (KindBurnDetail[] memory details) {
        details = new KindBurnDetail[](kinds.length);
        for (uint256 i = 0; i < kinds.length; i++) {
            details[i] = KindBurnDetail({
                kind: kinds[i],
                amount: _cumulativeKindAmount[kinds[i]],
                count: _cumulativeKindCount[kinds[i]],
                gas: _cumulativeKindGas[kinds[i]],
                gasUSDC: _cumulativeKindGasUsdc[kinds[i]]
            });
        }
    }

    // ==========================================
    // 周期统计报告 (offset n = 本周期 - n)，合并 BUnitAirdrop 事件 + BeamioBUnits mint/burn
    // 用户仅需 call BUnitAirdrop 即可获取某周期全部数据，无需再 call BeamioBUnits
    // ==========================================

    /**
     * @dev 本小时 - n 小时的完整统计。n=0 为当前小时。UTC 整点。
     */
    function getHourlyReport(uint256 n) external view returns (PeriodSummary memory report) {
        uint256 slot = block.timestamp / HOUR;
        if (n > slot) return report;
        PeriodEventStats storage s = _hourlyEventStats[slot - n];
        (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getHourlyReport(n);
        return PeriodSummary({
            airdropCount: s.airdropCount,
            burnCount: s.burnCount,
            gas: s.gas,
            gasUSDC: s.gasUSDC,
            bunitMint: mint,
            bunitBurn: burn,
            kindBurns: _getKindBurns(slot, n, _getKindList(), _hourlyKindAmount, _hourlyKindCount, _hourlyKindGas, _hourlyKindGasUsdc)
        });
    }

    /**
     * @dev 本日 - n 日的完整统计。n=0 为今日。UTC 0:00。
     */
    function getDailyReport(uint256 n) external view returns (PeriodSummary memory report) {
        uint256 slot = block.timestamp / DAY;
        if (n > slot) return report;
        PeriodEventStats storage s = _dailyEventStats[slot - n];
        (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getDailyReport(n);
        return PeriodSummary({
            airdropCount: s.airdropCount,
            burnCount: s.burnCount,
            gas: s.gas,
            gasUSDC: s.gasUSDC,
            bunitMint: mint,
            bunitBurn: burn,
            kindBurns: _getKindBurns(slot, n, _getKindList(), _dailyKindAmount, _dailyKindCount, _dailyKindGas, _dailyKindGasUsdc)
        });
    }

    /**
     * @dev 本周 - n 周的完整统计。n=0 为本周。周一 0:00 UTC 起。
     */
    function getWeeklyReport(uint256 n) external view returns (PeriodSummary memory report) {
        uint256 slot = (block.timestamp + WEEK_OFFSET) / WEEK;
        if (n > slot) return report;
        PeriodEventStats storage s = _weeklyEventStats[slot - n];
        (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getWeeklyReport(n);
        return PeriodSummary({
            airdropCount: s.airdropCount,
            burnCount: s.burnCount,
            gas: s.gas,
            gasUSDC: s.gasUSDC,
            bunitMint: mint,
            bunitBurn: burn,
            kindBurns: _getKindBurns(slot, n, _getKindList(), _weeklyKindAmount, _weeklyKindCount, _weeklyKindGas, _weeklyKindGasUsdc)
        });
    }

    /**
     * @dev 本月 - n 月的完整统计。n=0 为本月。自然月，1 日 0:00 UTC。
     */
    function getMonthlyReport(uint256 n) external view returns (PeriodSummary memory report) {
        uint256 slot = _getMonthSlot(block.timestamp);
        if (n > slot) return report;
        PeriodEventStats storage s = _monthlyEventStats[slot - n];
        (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getMonthlyReport(n);
        return PeriodSummary({
            airdropCount: s.airdropCount,
            burnCount: s.burnCount,
            gas: s.gas,
            gasUSDC: s.gasUSDC,
            bunitMint: mint,
            bunitBurn: burn,
            kindBurns: _getKindBurns(slot, n, _getKindList(), _monthlyKindAmount, _monthlyKindCount, _monthlyKindGas, _monthlyKindGasUsdc)
        });
    }

    /**
     * @dev 本季度 - n 季度的完整统计。n=0 为本季度。1/4/7/10 月 1 日 0:00 UTC。
     */
    function getQuarterlyReport(uint256 n) external view returns (PeriodSummary memory report) {
        uint256 slot = _getQuarterSlot(block.timestamp);
        if (n > slot) return report;
        PeriodEventStats storage s = _quarterlyEventStats[slot - n];
        (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getQuarterlyReport(n);
        return PeriodSummary({
            airdropCount: s.airdropCount,
            burnCount: s.burnCount,
            gas: s.gas,
            gasUSDC: s.gasUSDC,
            bunitMint: mint,
            bunitBurn: burn,
            kindBurns: _getKindBurns(slot, n, _getKindList(), _quarterlyKindAmount, _quarterlyKindCount, _quarterlyKindGas, _quarterlyKindGasUsdc)
        });
    }

    /**
     * @dev 本年 - n 年的完整统计。n=0 为本年。自然年，1 月 1 日 0:00 UTC。
     */
    function getYearlyReport(uint256 n) external view returns (PeriodSummary memory report) {
        uint256 slot = _getYearSlot(block.timestamp);
        if (n > slot) return report;
        PeriodEventStats storage s = _yearlyEventStats[slot - n];
        (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getYearlyReport(n);
        return PeriodSummary({
            airdropCount: s.airdropCount,
            burnCount: s.burnCount,
            gas: s.gas,
            gasUSDC: s.gasUSDC,
            bunitMint: mint,
            bunitBurn: burn,
            kindBurns: _getKindBurns(slot, n, _getKindList(), _yearlyKindAmount, _yearlyKindCount, _yearlyKindGas, _yearlyKindGasUsdc)
        });
    }

    // ==========================================
    // 窗口期完整报告：汇总 + kind 焚烧明细，一次返回
    // ==========================================

    function getHourlyReportFull(uint256 n, uint256[] calldata kinds) external view returns (PeriodSummary memory summary, KindBurnDetail[] memory kindBurns) {
        uint256 slot = block.timestamp / HOUR;
        kindBurns = _getKindBurns(slot, n, kinds, _hourlyKindAmount, _hourlyKindCount, _hourlyKindGas, _hourlyKindGasUsdc);
        if (n <= slot) {
            PeriodEventStats storage s = _hourlyEventStats[slot - n];
            (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getHourlyReport(n);
            summary = PeriodSummary({airdropCount: s.airdropCount, burnCount: s.burnCount, gas: s.gas, gasUSDC: s.gasUSDC, bunitMint: mint, bunitBurn: burn, kindBurns: kindBurns});
        }
    }

    function getDailyReportFull(uint256 n, uint256[] calldata kinds) external view returns (PeriodSummary memory summary, KindBurnDetail[] memory kindBurns) {
        uint256 slot = block.timestamp / DAY;
        kindBurns = _getKindBurns(slot, n, kinds, _dailyKindAmount, _dailyKindCount, _dailyKindGas, _dailyKindGasUsdc);
        if (n <= slot) {
            PeriodEventStats storage s = _dailyEventStats[slot - n];
            (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getDailyReport(n);
            summary = PeriodSummary({airdropCount: s.airdropCount, burnCount: s.burnCount, gas: s.gas, gasUSDC: s.gasUSDC, bunitMint: mint, bunitBurn: burn, kindBurns: kindBurns});
        }
    }

    function getWeeklyReportFull(uint256 n, uint256[] calldata kinds) external view returns (PeriodSummary memory summary, KindBurnDetail[] memory kindBurns) {
        uint256 slot = (block.timestamp + WEEK_OFFSET) / WEEK;
        kindBurns = _getKindBurns(slot, n, kinds, _weeklyKindAmount, _weeklyKindCount, _weeklyKindGas, _weeklyKindGasUsdc);
        if (n <= slot) {
            PeriodEventStats storage s = _weeklyEventStats[slot - n];
            (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getWeeklyReport(n);
            summary = PeriodSummary({airdropCount: s.airdropCount, burnCount: s.burnCount, gas: s.gas, gasUSDC: s.gasUSDC, bunitMint: mint, bunitBurn: burn, kindBurns: kindBurns});
        }
    }

    function getMonthlyReportFull(uint256 n, uint256[] calldata kinds) external view returns (PeriodSummary memory summary, KindBurnDetail[] memory kindBurns) {
        uint256 slot = _getMonthSlot(block.timestamp);
        kindBurns = _getKindBurns(slot, n, kinds, _monthlyKindAmount, _monthlyKindCount, _monthlyKindGas, _monthlyKindGasUsdc);
        if (n <= slot) {
            PeriodEventStats storage s = _monthlyEventStats[slot - n];
            (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getMonthlyReport(n);
            summary = PeriodSummary({airdropCount: s.airdropCount, burnCount: s.burnCount, gas: s.gas, gasUSDC: s.gasUSDC, bunitMint: mint, bunitBurn: burn, kindBurns: kindBurns});
        }
    }

    function getQuarterlyReportFull(uint256 n, uint256[] calldata kinds) external view returns (PeriodSummary memory summary, KindBurnDetail[] memory kindBurns) {
        uint256 slot = _getQuarterSlot(block.timestamp);
        kindBurns = _getKindBurns(slot, n, kinds, _quarterlyKindAmount, _quarterlyKindCount, _quarterlyKindGas, _quarterlyKindGasUsdc);
        if (n <= slot) {
            PeriodEventStats storage s = _quarterlyEventStats[slot - n];
            (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getQuarterlyReport(n);
            summary = PeriodSummary({airdropCount: s.airdropCount, burnCount: s.burnCount, gas: s.gas, gasUSDC: s.gasUSDC, bunitMint: mint, bunitBurn: burn, kindBurns: kindBurns});
        }
    }

    function getYearlyReportFull(uint256 n, uint256[] calldata kinds) external view returns (PeriodSummary memory summary, KindBurnDetail[] memory kindBurns) {
        uint256 slot = _getYearSlot(block.timestamp);
        kindBurns = _getKindBurns(slot, n, kinds, _yearlyKindAmount, _yearlyKindCount, _yearlyKindGas, _yearlyKindGasUsdc);
        if (n <= slot) {
            PeriodEventStats storage s = _yearlyEventStats[slot - n];
            (uint256 mint, uint256 burn) = IBeamioBUnits(address(bunit)).getYearlyReport(n);
            summary = PeriodSummary({airdropCount: s.airdropCount, burnCount: s.burnCount, gas: s.gas, gasUSDC: s.gasUSDC, bunitMint: mint, bunitBurn: burn, kindBurns: kindBurns});
        }
    }

    function _getKindList() private view returns (uint256[] memory) {
        uint256 len = _kindList.length;
        uint256[] memory list = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            list[i] = _kindList[i];
        }
        return list;
    }

    function _getKindBurns(
        uint256 slot,
        uint256 n,
        uint256[] memory kinds,
        mapping(uint256 => mapping(uint256 => uint256)) storage amountMap,
        mapping(uint256 => mapping(uint256 => uint256)) storage countMap,
        mapping(uint256 => mapping(uint256 => uint256)) storage gasMap,
        mapping(uint256 => mapping(uint256 => uint256)) storage gasUsdcMap
    ) private view returns (KindBurnDetail[] memory details) {
        if (n > slot) return new KindBurnDetail[](0);
        uint256 s = slot - n;
        details = new KindBurnDetail[](kinds.length);
        for (uint256 i = 0; i < kinds.length; i++) {
            details[i] = KindBurnDetail({
                kind: kinds[i],
                amount: amountMap[s][kinds[i]],
                count: countMap[s][kinds[i]],
                gas: gasMap[s][kinds[i]],
                gasUSDC: gasUsdcMap[s][kinds[i]]
            });
        }
    }

    // ==========================================
    // 窗口期内按 kind 分类的焚烧明细
    // ==========================================

    /**
     * @dev 本小时 - n 小时内各 kind 的焚烧明细。kinds 为要查询的分类数组。
     */
    function getHourlyKindBurns(uint256 n, uint256[] calldata kinds) external view returns (KindBurnDetail[] memory details) {
        uint256 slot = block.timestamp / HOUR;
        if (n > slot) return new KindBurnDetail[](0);
        uint256 s = slot - n;
        details = new KindBurnDetail[](kinds.length);
        for (uint256 i = 0; i < kinds.length; i++) {
            details[i] = KindBurnDetail({
                kind: kinds[i],
                amount: _hourlyKindAmount[s][kinds[i]],
                count: _hourlyKindCount[s][kinds[i]],
                gas: _hourlyKindGas[s][kinds[i]],
                gasUSDC: _hourlyKindGasUsdc[s][kinds[i]]
            });
        }
    }

    /**
     * @dev 本日 - n 日内各 kind 的焚烧明细。
     */
    function getDailyKindBurns(uint256 n, uint256[] calldata kinds) external view returns (KindBurnDetail[] memory details) {
        uint256 slot = block.timestamp / DAY;
        if (n > slot) return new KindBurnDetail[](0);
        uint256 s = slot - n;
        details = new KindBurnDetail[](kinds.length);
        for (uint256 i = 0; i < kinds.length; i++) {
            details[i] = KindBurnDetail({
                kind: kinds[i],
                amount: _dailyKindAmount[s][kinds[i]],
                count: _dailyKindCount[s][kinds[i]],
                gas: _dailyKindGas[s][kinds[i]],
                gasUSDC: _dailyKindGasUsdc[s][kinds[i]]
            });
        }
    }

    /**
     * @dev 本周 - n 周内各 kind 的焚烧明细。
     */
    function getWeeklyKindBurns(uint256 n, uint256[] calldata kinds) external view returns (KindBurnDetail[] memory details) {
        uint256 slot = (block.timestamp + WEEK_OFFSET) / WEEK;
        if (n > slot) return new KindBurnDetail[](0);
        uint256 s = slot - n;
        details = new KindBurnDetail[](kinds.length);
        for (uint256 i = 0; i < kinds.length; i++) {
            details[i] = KindBurnDetail({
                kind: kinds[i],
                amount: _weeklyKindAmount[s][kinds[i]],
                count: _weeklyKindCount[s][kinds[i]],
                gas: _weeklyKindGas[s][kinds[i]],
                gasUSDC: _weeklyKindGasUsdc[s][kinds[i]]
            });
        }
    }

    /**
     * @dev 本月 - n 月内各 kind 的焚烧明细。
     */
    function getMonthlyKindBurns(uint256 n, uint256[] calldata kinds) external view returns (KindBurnDetail[] memory details) {
        uint256 slot = _getMonthSlot(block.timestamp);
        if (n > slot) return new KindBurnDetail[](0);
        uint256 s = slot - n;
        details = new KindBurnDetail[](kinds.length);
        for (uint256 i = 0; i < kinds.length; i++) {
            details[i] = KindBurnDetail({
                kind: kinds[i],
                amount: _monthlyKindAmount[s][kinds[i]],
                count: _monthlyKindCount[s][kinds[i]],
                gas: _monthlyKindGas[s][kinds[i]],
                gasUSDC: _monthlyKindGasUsdc[s][kinds[i]]
            });
        }
    }

    /**
     * @dev 本季度 - n 季度内各 kind 的焚烧明细。
     */
    function getQuarterlyKindBurns(uint256 n, uint256[] calldata kinds) external view returns (KindBurnDetail[] memory details) {
        uint256 slot = _getQuarterSlot(block.timestamp);
        if (n > slot) return new KindBurnDetail[](0);
        uint256 s = slot - n;
        details = new KindBurnDetail[](kinds.length);
        for (uint256 i = 0; i < kinds.length; i++) {
            details[i] = KindBurnDetail({
                kind: kinds[i],
                amount: _quarterlyKindAmount[s][kinds[i]],
                count: _quarterlyKindCount[s][kinds[i]],
                gas: _quarterlyKindGas[s][kinds[i]],
                gasUSDC: _quarterlyKindGasUsdc[s][kinds[i]]
            });
        }
    }

    /**
     * @dev 本年 - n 年内各 kind 的焚烧明细。
     */
    function getYearlyKindBurns(uint256 n, uint256[] calldata kinds) external view returns (KindBurnDetail[] memory details) {
        uint256 slot = _getYearSlot(block.timestamp);
        if (n > slot) return new KindBurnDetail[](0);
        uint256 s = slot - n;
        details = new KindBurnDetail[](kinds.length);
        for (uint256 i = 0; i < kinds.length; i++) {
            details[i] = KindBurnDetail({
                kind: kinds[i],
                amount: _yearlyKindAmount[s][kinds[i]],
                count: _yearlyKindCount[s][kinds[i]],
                gas: _yearlyKindGas[s][kinds[i]],
                gasUSDC: _yearlyKindGasUsdc[s][kinds[i]]
            });
        }
    }

    /**
     * @dev 返回空投统计：免费池与付费池各自的累计空投量 (6 位精度)。
     *      当前仅 claim/claimFor 走免费池；付费池预留供后续扩展。
     */
    function getAirdropStats() external view returns (uint256 freeAirdropped, uint256 paidAirdropped, uint256 totalAirdropped) {
        freeAirdropped = totalFreeAirdropped;
        paidAirdropped = totalPaidAirdropped;
        totalAirdropped = totalFreeAirdropped + totalPaidAirdropped;
    }

    /**
     * @dev 返回焚烧统计 (读取 BeamioBUnits 状态)：免费池与付费池各自的累计焚烧量 (6 位精度)。
     */
    function getBurnStats() external view returns (uint256 freeBurned, uint256 paidBurned, uint256 totalBurned) {
        IBeamioBUnits bu = IBeamioBUnits(address(bunit));
        freeBurned = bu.totalFreeBurned();
        paidBurned = bu.totalPaidBurned();
        totalBurned = freeBurned + paidBurned;
    }

    /**
     * @dev 返回 B-Units 综合统计报告：空投 + 焚烧，统一入口。
     */
    function getBUnitReport() external view returns (BUnitReport memory report) {
        report.freeAirdropped = totalFreeAirdropped;
        report.paidAirdropped = totalPaidAirdropped;
        report.totalAirdropped = totalFreeAirdropped + totalPaidAirdropped;
        IBeamioBUnits bu = IBeamioBUnits(address(bunit));
        report.freeBurned = bu.totalFreeBurned();
        report.paidBurned = bu.totalPaidBurned();
        report.totalBurned = report.freeBurned + report.paidBurned;
    }

    /**
     * @dev 获取 address 的 B-Units 余额。
     */
    function getBUnitBalance(address account) external view returns (uint256) {
        return bunit.balanceOf(account);
    }

    /**
     * @dev 从 BeamioIndexerDiamond 获取 address 在指定 (cards, tokenIds) 上的 BeamioUserCard 资产余额。
     *      cards 与 tokenIds 长度必须相同。使用合约内配置的 beamioIndexerDiamond 地址。
     */
    function getBeamioUserCardBalances(
        address account,
        address[] calldata cards,
        uint256[] calldata tokenIds
    ) external view returns (CardBalance[] memory) {
        require(cards.length == tokenIds.length, "length mismatch");
        require(beamioIndexerDiamond != address(0), "indexer not set");
        CardBalance[] memory result = new CardBalance[](cards.length);
        IBeamioIndexerDiamond idx = IBeamioIndexerDiamond(beamioIndexerDiamond);
        for (uint256 i = 0; i < cards.length; i++) {
            result[i] = CardBalance({
                card: cards[i],
                tokenId: tokenIds[i],
                balanceE6: idx.getBeamioUserCardTokenIndexedBalance(cards[i], tokenIds[i], account)
            });
        }
        return result;
    }

    /**
     * @dev 从 BeamioIndexerDiamond Catalog 获取所有已注册卡片，返回 address 在各卡 tokenId=0 上的余额（仅 balance>0）。
     *      最多扫描 maxCards 张卡，避免 gas 超限。使用合约内配置的 beamioIndexerDiamond 地址。
     */
    function getBeamioUserCardBalancesFromCatalog(
        address account,
        uint256 maxCards
    ) external view returns (address[] memory cards, uint256[] memory balancesE6) {
        require(beamioIndexerDiamond != address(0), "indexer not set");
        IBeamioIndexerDiamond idx = IBeamioIndexerDiamond(beamioIndexerDiamond);
        uint256 total = idx.getAllCardsCount();
        if (total == 0) return (new address[](0), new uint256[](0));

        uint256 limit = maxCards > total ? total : maxCards;
        address[] memory allCards = idx.getAllCardsPaged(0, limit);

        address[] memory tmpCards = new address[](allCards.length);
        uint256[] memory tmpBalances = new uint256[](allCards.length);
        uint256 count = 0;

        for (uint256 i = 0; i < allCards.length; i++) {
            address card = allCards[i];
            if (card == address(0)) continue;
            uint256 bal = idx.getBeamioUserCardTokenIndexedBalance(card, 0, account);
            if (bal > 0) {
                tmpCards[count] = card;
                tmpBalances[count] = bal;
                count++;
            }
        }

        cards = new address[](count);
        balancesE6 = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            cards[i] = tmpCards[i];
            balancesE6[i] = tmpBalances[i];
        }
        return (cards, balancesE6);
    }


}
