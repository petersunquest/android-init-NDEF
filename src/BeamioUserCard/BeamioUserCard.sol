// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioERC1155Logic.sol";
import "./BeamioCurrency.sol";
import "./Errors.sol";
import "./RedeemStorage.sol";

import "../contracts/token/ERC1155/ERC1155.sol";
import "../contracts/access/Ownable.sol";
import "../contracts/utils/ReentrancyGuard.sol";

/* =========================
   Interfaces
   ========================= */
// 注意：IBeamioFactoryOracle, IBeamioAccountFactoryV07 已在 BeamioERC1155Logic.sol 中定义（资金流已移至 Factory）

interface IBeamioGatewayAAFactoryGetter {
    function _aaFactory() external view returns (address);
}

interface IBeamioUserCardFactoryPaymasterV07 {
    function defaultRedeemModule() external view returns (address);
}

/**
 * @dev RedeemModule VNext ABI (delegatecall target)
 */
interface IBeamioRedeemModuleVNext {
    function createRedeem(
        bytes32 hash,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external;

    function cancelRedeem(string calldata code) external;

    function consumeRedeem(string calldata code, address to)
        external
        returns (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts);

    function createRedeemBatch(
        bytes32[] calldata hashes,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external;

    function consumeRedeemBatch(string[] calldata codes, address to)
        external
        returns (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts);

    function createRedeemPool(
        bytes32 poolHash,
        uint64 validAfter,
        uint64 validBefore,
        uint256[][] calldata tokenIdsList,
        uint256[][] calldata amountsList,
        uint32[] calldata counts
    ) external;

    function terminateRedeemPool(bytes32 poolHash) external;

    function consumeRedeemPool(string calldata code, address user)
        external
        returns (uint256[] memory tokenIds, uint256[] memory amounts);
}



/* =========================================================
   BeamioUserCard
   ========================================================= */

contract BeamioUserCard is ERC1155, Ownable, ReentrancyGuard {
    using BeamioCurrency for *;

    // ===== Versioning =====
    uint256 public constant VERSION = 10;

    // ===== Constants (no magic numbers) =====
    uint256 public constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint8 public constant POINTS_DECIMALS = BeamioERC1155Logic.POINTS_DECIMALS;
    uint256 private constant POINTS_ONE = 10 ** uint256(POINTS_DECIMALS);

    uint256 public constant NFT_START_ID = BeamioERC1155Logic.NFT_START_ID;
    uint256 public constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;

    // ===== Immutable / gateway =====
    address public immutable deployer;
    address public gateway;
    address public debugGateway; // allow debug override

    function factoryGateway() public view returns (address) {
        return gateway;
    }

    modifier onlyAuthorizedGateway() {
        address gw = debugGateway == address(0) ? gateway : debugGateway;
        if (msg.sender != gw) revert UC_UnauthorizedGateway();
        _;
    }

    // ===== Pricing =====
    BeamioCurrency.CurrencyType public currency;
    /// @dev 单价：每 1e6 points 的价格，货币单位 E6（与购买时 USDC 1e6 一致）
    uint256 public pointsUnitPriceInCurrencyE6;

    // ===== per-card expiry policy =====
    uint256 public expirySeconds; // 0 = never expire
    event ExpirySecondsUpdated(uint256 oldSecs, uint256 newSecs);
    event PointsUnitPriceUpdated(uint256 priceInCurrencyE6);

    // ===== multisig governance =====
    uint256 public threshold;
    mapping(address => bool) public isAdmin;
    address[] public adminList;

    struct Proposal {
        address target;
        uint256 v1;
        uint256 v2;
        uint256 v3;
        bytes4 selector;
        uint256 approvals;
        bool executed;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public isApproved;
    uint256 public proposalCount;

    event ProposalCreated(uint256 indexed id, bytes4 indexed selector, address indexed proposer);
    event ProposalApproved(uint256 indexed id, address indexed admin);
    event ProposalExecuted(uint256 indexed id);

    modifier onlyAdmin() {
        if (!isAdmin[msg.sender]) revert UC_NotAdmin();
        _;
    }

    // ===== whitelist =====
    mapping(address => bool) public transferWhitelist;
    bool public transferWhitelistEnabled;
    event TransferWhitelistEnabledUpdated(bool enabled);

    function _setTransferWhitelistEnabled(bool enabled) internal {
        transferWhitelistEnabled = enabled;
        emit TransferWhitelistEnabledUpdated(enabled);
    }

    function setTransferWhitelistEnabled(bool enabled) external {
        _requireOwnerOrGateway();
        _setTransferWhitelistEnabled(enabled);
    }

    // ===== membership state =====
    mapping(uint256 => uint256) public expiresAt;
    mapping(uint256 => uint256) public attributes;
    mapping(uint256 => uint256) public tokenTierIndexOrMax;
    mapping(address => uint256[]) public _userOwnedNfts;

    mapping(address => uint256) public activeMembershipId;
    mapping(address => uint256) public activeTierIndexOrMax;

    struct NFTDetail {
        uint256 tokenId;
        uint256 attribute;
        uint256 tierIndexOrMax;
        uint256 expiry;
        bool isExpired;
    }

    // ===== tiers =====
    struct Tier {
        uint256 minUsdc6; // semantic: minPointsDelta6
        uint256 attr;
        uint256 tierExpirySeconds; // 0 => use global expirySeconds
    }
    Tier[] public tiers;
    uint256 public defaultAttrWhenNoTiers;

    event TiersUpdated(uint256 count);
    event TierAppended(uint256 index, uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds);
    event DefaultAttrUpdated(uint256 attr);

    event MemberNFTIssued(address indexed user, uint256 indexed tokenId, uint256 tierIndexOrMax, uint256 minUsdc6, uint256 expiry);
    event MemberNFTUpgraded(address indexed user, uint256 indexed oldActiveTokenId, uint256 indexed newTokenId, uint256 oldTierIndexOrMax, uint256 newTierIndex, uint256 newExpiry);

    event PointsPurchasedWithUSDC(
        address indexed payerEOA,
        address indexed beneficiaryAccount,
        address indexed usdc,
        uint256 usdcIn6,
        uint256 pointsMinted6,
        uint256 unitPointPriceUsdc6,
        bytes32 nonce
    );

    event AdminCardMinted(address indexed beneficiaryAccount, uint256 indexed tokenId, uint256 attr, uint256 expiry);
    event AdminPointsMinted(address indexed beneficiaryAccount, uint256 points6);
    event PointsMintedByGateway(address indexed userEOA, address indexed acct, uint256 points6);

    // ===== Faucet data =====
    struct FaucetConfig {
        uint64 validUntil;
        uint64 perClaimMax;
        uint128 maxPerUser;
        uint128 maxGlobal;
        bool enabled;

        uint8 currency;
        uint8 decimals;           // MUST be POINTS_DECIMALS
        uint128 priceInCurrency6; // 0 free; >0 priced
    }

    mapping(uint256 => FaucetConfig) public faucetConfig;
    mapping(uint256 => mapping(address => uint256)) public faucetClaimed;
    mapping(uint256 => uint256) public faucetGlobalMinted;
    mapping(uint256 => bool) public faucetConfigFrozen;

    event FaucetConfigUpdated(uint256 indexed id, FaucetConfig cfg);
    event FaucetClaimed(uint256 indexed id, address indexed userEOA, address indexed acct, uint256 amount, uint256 claimedAfter);

    event IssuedNftCreated(uint256 indexed tokenId, bytes32 title, uint64 validAfter, uint64 validBefore, uint256 maxSupply, uint256 priceInCurrency6, bytes32 sharedMetadataHash);
    event IssuedNftMinted(uint256 indexed tokenId, address indexed recipient, uint256 amount);

    // ===== current index =====
    uint256 private _currentIndex = NFT_START_ID;
    uint256 private _issuedNftIndex = ISSUED_NFT_START_ID;
    mapping(uint256 => uint64) public issuedNftValidAfter;
    mapping(uint256 => uint64) public issuedNftValidBefore;
    mapping(uint256 => bytes32) public issuedNftTitle;
    mapping(uint256 => bytes32) public issuedNftSharedMetadataHash; // 0 => no shared metadata; else hash of IPFS JSON (e.g. keccak256(cid))
    mapping(uint256 => uint256) public issuedNftMaxSupply;
    mapping(uint256 => uint256) public issuedNftMintedCount;
    mapping(uint256 => uint256) public issuedNftPriceInCurrency6;

    // ===== Redeem Events (emitted by card; module also emits its own) =====
    event RedeemCreated(bytes32 indexed hash, uint256 points6, uint256 attr);
    event RedeemCancelled(bytes32 indexed hash);

    // ==========================================================
    // ctor
    // ==========================================================
    constructor(
        string memory uri_,
        BeamioCurrency.CurrencyType currency_,
        uint256 pointsUnitPriceInCurrencyE6_,
        address initialOwner,
        address gateway_
    ) ERC1155(uri_) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert BM_ZeroAddress();
        if (gateway_ == address(0) || gateway_.code.length == 0) revert UC_GlobalMisconfigured();

        deployer = msg.sender;
        gateway = gateway_;
        debugGateway = gateway_;

        currency = currency_;
        pointsUnitPriceInCurrencyE6 = pointsUnitPriceInCurrencyE6_;

        threshold = 1;
        isAdmin[initialOwner] = true;
        adminList.push(initialOwner);
    }

    // ==========================================================
    // Tiers
    // ==========================================================
    function setDefaultAttr(uint256 attr) external {
        _requireOwnerOrGateway();
        emit DefaultAttrUpdated(defaultAttrWhenNoTiers);
        defaultAttrWhenNoTiers = attr;
    }

    function appendTier(uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds) external {
        _requireOwnerOrGateway();
        if (minUsdc6 == 0) revert UC_TierMinZero();
        if (tiers.length > 0) {
            Tier memory last = tiers[tiers.length - 1];
            // strict decreasing
            if (minUsdc6 >= last.minUsdc6) revert UC_TiersNotDecreasing();
        }
        uint256 idx = tiers.length;
        tiers.push(Tier(minUsdc6, attr, tierExpirySeconds));
        emit TierAppended(idx, minUsdc6, attr, tierExpirySeconds);
    }

    function setTiers(Tier[] calldata newTiers) external {
        _requireOwnerOrGateway();
        if (newTiers.length == 0) revert UC_TierLenMismatch();

        uint256 prev = type(uint256).max;
        for (uint256 i = 0; i < newTiers.length; i++) {
            uint256 minPointsDelta6 = newTiers[i].minUsdc6;
            if (minPointsDelta6 == 0) revert UC_TierMinZero();
            if (minPointsDelta6 >= prev) revert UC_TiersNotDecreasing();
            prev = minPointsDelta6;
        }

        delete tiers;
        for (uint256 i = 0; i < newTiers.length; i++) tiers.push(newTiers[i]);
        emit TiersUpdated(newTiers.length);
    }

    function getTiersCount() external view returns (uint256) { return tiers.length; }
    function getTierAt(uint256 idx) external view returns (Tier memory) { return tiers[idx]; }

    // ==========================================================
    // Pricing
    // ==========================================================
    function setPointsUnitPrice(uint256 priceInCurrencyE6) external {
        _requireOwnerOrGateway();
        if (priceInCurrencyE6 == 0) revert UC_PriceZero();
        pointsUnitPriceInCurrencyE6 = priceInCurrencyE6;
        emit PointsUnitPriceUpdated(priceInCurrencyE6);
    }

    function setExpirySeconds(uint256 secs) external {
        _requireOwnerOrGateway();
        emit ExpirySecondsUpdated(expirySeconds, secs);
        expirySeconds = secs;
    }

    // ==========================================================
    // Faucet config
    // ==========================================================
    function setFaucetConfig(
        uint256 id,
        uint64 validUntil,
        uint64 perClaimMax,
        uint128 maxPerUser,
        uint128 maxGlobal,
        bool enabled,
        BeamioCurrency.CurrencyType cur,
        uint128 priceInCurrency6
    ) external onlyAuthorizedGateway {
        if (faucetConfigFrozen[id]) revert UC_FaucetConfigFrozen();

        FaucetConfig storage cfg = faucetConfig[id];
        cfg.validUntil = validUntil;
        cfg.perClaimMax = perClaimMax;
        cfg.maxPerUser = maxPerUser;
        cfg.maxGlobal = maxGlobal;
        cfg.enabled = enabled;
        cfg.currency = uint8(cur);
        cfg.decimals = POINTS_DECIMALS;
        cfg.priceInCurrency6 = priceInCurrency6;

        _validateFaucetConfig(cfg);
        faucetConfigFrozen[id] = true;

        emit FaucetConfigUpdated(id, cfg);
    }

    function _validateFaucetConfig(FaucetConfig memory cfg) private pure {
        if (!cfg.enabled && cfg.validUntil == 0) revert UC_FaucetConfigInvalid();
        if (cfg.decimals != POINTS_DECIMALS) revert UC_FaucetConfigInvalid();
        if (cfg.perClaimMax == 0) revert UC_FaucetConfigInvalid();
        if (cfg.maxPerUser == 0 || cfg.maxGlobal == 0) revert UC_FaucetConfigInvalid();
    }

    // ==========================================================
    // Faucet (free)
    // ==========================================================
    function faucetByGateway(address userEOA, uint256 id, uint256 amount)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();

        FaucetConfig storage cfg = faucetConfig[id];
        if (!cfg.enabled) revert UC_FaucetNotEnabled();
        if (block.timestamp > cfg.validUntil) revert UC_FaucetExpired();
        if (amount > cfg.perClaimMax) revert UC_FaucetAmountTooLarge();
        if (!IBeamioFactoryOracle(factoryGateway()).isTokenIdIssued(address(this), id)) revert UC_FaucetIdNotIssued();
        if (cfg.priceInCurrency6 != 0) revert UC_FaucetDisabledBecausePriced();

        if (faucetClaimed[id][userEOA] + amount > cfg.maxPerUser) revert UC_FaucetMaxExceeded();
        if (faucetGlobalMinted[id] + amount > cfg.maxGlobal) revert UC_FaucetGlobalMaxExceeded();

        faucetClaimed[id][userEOA] += amount;
        faucetGlobalMinted[id] += amount;

        address acct = _toAccount(userEOA);

        _syncActiveToBestValid(acct);
        bool hasValidCard = (activeMembershipId[acct] != 0);

        _mint(acct, id, amount, "");

        uint256 pointsDelta6 = (id == POINTS_ID) ? amount : 0;
        if (!hasValidCard) _issueCardByPointsDelta_AssumingNoValidCard(acct, pointsDelta6);

        emit FaucetClaimed(id, userEOA, acct, amount, faucetClaimed[id][userEOA]);
    }

    /// @notice Gateway mint for paid faucet；资金流由 FactoryPaymaster.purchaseFaucetForUser 处理
    function mintFaucetByGateway(address userEOA, uint256 id, uint256 amount6) external onlyAuthorizedGateway nonReentrant {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount6 == 0) revert UC_AmountZero();

        FaucetConfig storage cfg = faucetConfig[id];
        if (!cfg.enabled) revert UC_FaucetNotEnabled();
        if (block.timestamp > cfg.validUntil) revert UC_FaucetExpired();
        if (amount6 > cfg.perClaimMax) revert UC_FaucetAmountTooLarge();
        if (!IBeamioFactoryOracle(factoryGateway()).isTokenIdIssued(address(this), id)) revert UC_FaucetIdNotIssued();
        if (cfg.priceInCurrency6 == 0) revert UC_PurchaseDisabledBecauseFree();

        if (faucetClaimed[id][userEOA] + amount6 > cfg.maxPerUser) revert UC_FaucetMaxExceeded();
        if (faucetGlobalMinted[id] + amount6 > cfg.maxGlobal) revert UC_FaucetGlobalMaxExceeded();

        faucetClaimed[id][userEOA] += amount6;
        faucetGlobalMinted[id] += amount6;

        address acct = _toAccount(userEOA);
        _mint(acct, id, amount6, "");

        emit FaucetClaimed(id, userEOA, acct, amount6, faucetClaimed[id][userEOA]);
    }

    // ==========================================================
    // Redeem suite (owner issues; gateway consumes)
    // ==========================================================

    /// @notice card owner (or gateway) creates a one-time redeem
    function createRedeem(
        bytes32 hash,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        _requireOwnerOrGateway();

        address module = _redeemModule();
        (bool ok, bytes memory data) = module.delegatecall(
            abi.encodeWithSelector(
                IBeamioRedeemModuleVNext.createRedeem.selector,
                hash,
                points6,
                attr,
                validAfter,
                validBefore,
                tokenIds,
                amounts
            )
        );
        if (!ok) revert UC_RedeemDelegateFailed(data);

        emit RedeemCreated(hash, points6, attr);
    }

    /// @notice card owner (or gateway) creates batch one-time redeems (same content, multiple hashes)
    function createRedeemBatch(
        bytes32[] calldata hashes,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        _requireOwnerOrGateway();

        address module = _redeemModule();
        (bool ok, bytes memory data) = module.delegatecall(
            abi.encodeWithSelector(
                IBeamioRedeemModuleVNext.createRedeemBatch.selector,
                hashes,
                points6,
                attr,
                validAfter,
                validBefore,
                tokenIds,
                amounts
            )
        );
        if (!ok) revert UC_RedeemDelegateFailed(data);

        for (uint256 i = 0; i < hashes.length; i++) {
            emit RedeemCreated(hashes[i], points6, attr);
        }
    }

    /// @notice 最大迭代次数，防止存储损坏（如旧布局/异常数据）导致 length 异常大而 overflow
    uint256 private constant _MAX_BUNDLE_LEN = 64;
    uint256 private constant _MAX_POOL_CONTAINERS = 32;

    /// @notice 计算 one-time redeem 总点数：r.points6 + token bundle 中 POINTS_ID 的 amounts
    /// @dev 使用 min(tokenIds.length, amounts.length) 防止存储损坏导致两数组长度不一致时越界 revert
    function _redeemTotalPoints(RedeemStorage.Redeem storage r) internal view returns (uint256) {
        uint256 t = r.points6;
        uint256 len = r.tokenIds.length;
        if (r.amounts.length < len) len = r.amounts.length;
        if (len > _MAX_BUNDLE_LEN) len = _MAX_BUNDLE_LEN;
        for (uint256 i = 0; i < len; i++) {
            if (r.tokenIds[i] == POINTS_ID) t += r.amounts[i];
        }
        return t;
    }

    /// @notice 计算 pool 总点数：遍历 containers 中 POINTS_ID 的 amounts
    /// @dev 使用 min(tokenIds.length, amounts.length) 防止存储损坏导致两数组长度不一致时越界 revert
    function _poolTotalPoints(RedeemStorage.RedeemPool storage p) internal view returns (uint256) {
        uint256 t = 0;
        uint256 cLen = p.containers.length;
        if (cLen > _MAX_POOL_CONTAINERS) cLen = _MAX_POOL_CONTAINERS;
        for (uint256 c = 0; c < cLen; c++) {
            RedeemStorage.PoolContainer storage pc = p.containers[c];
            uint256 pcLen = pc.tokenIds.length;
            if (pc.amounts.length < pcLen) pcLen = pc.amounts.length;
            if (pcLen > _MAX_BUNDLE_LEN) pcLen = _MAX_BUNDLE_LEN;
            for (uint256 i = 0; i < pcLen; i++) {
                if (pc.tokenIds[i] == POINTS_ID) t += pc.amounts[i];
            }
        }
        return t;
    }

    /// @notice 统一查询：active=true 表示可兑换，totalPoints6 含 token bundle 中 POINTS_ID
    function getRedeemStatus(bytes32 hash) external view returns (bool active, uint256 totalPoints6) {
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return (true, _redeemTotalPoints(r));
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active && p.totalRemaining > 0) return (true, _poolTotalPoints(p));
        return (false, 0);
    }

    /// @notice 批量查询：输入 string[] codes，返回 (active[], totalPoints6[])，totalPoints6 含 token bundle 中 POINTS_ID
    function getRedeemStatusBatch(string[] calldata codes) external view returns (bool[] memory active, uint256[] memory totalPoints6) {
        uint256 n = codes.length;
        active = new bool[](n);
        totalPoints6 = new uint256[](n);
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        for (uint256 i = 0; i < n; i++) {
            bytes32 hash = keccak256(bytes(codes[i]));
            RedeemStorage.Redeem storage r = l.redeems[hash];
            if (r.active) {
                active[i] = true;
                totalPoints6[i] = _redeemTotalPoints(r);
            } else {
                RedeemStorage.RedeemPool storage p = l.pools[hash];
                if (p.active && p.totalRemaining > 0) {
                    active[i] = true;
                    totalPoints6[i] = _poolTotalPoints(p);
                }
            }
        }
    }

    /// @notice 批量查询：输入 bytes32[] hashes（已有 hash 时使用），返回 (active[], totalPoints6[])
    function getRedeemStatusBatch(bytes32[] calldata hashes) external view returns (bool[] memory active, uint256[] memory totalPoints6) {
        uint256 n = hashes.length;
        active = new bool[](n);
        totalPoints6 = new uint256[](n);
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        for (uint256 i = 0; i < n; i++) {
            bytes32 hash = hashes[i];
            RedeemStorage.Redeem storage r = l.redeems[hash];
            if (r.active) {
                active[i] = true;
                totalPoints6[i] = _redeemTotalPoints(r);
            } else {
                RedeemStorage.RedeemPool storage p = l.pools[hash];
                if (p.active && p.totalRemaining > 0) {
                    active[i] = true;
                    totalPoints6[i] = _poolTotalPoints(p);
                }
            }
        }
    }

    /// @notice 统一查询（含 claimer）：对 pool 会检查 claimer 是否已领取
    function getRedeemStatusEx(bytes32 hash, address claimer) external view returns (bool active, uint128 points6, bool isPool) {
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return (true, r.points6, false);
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active && p.totalRemaining > 0) {
            if (claimer != address(0) && l.poolClaimed[hash][claimer]) return (false, 0, true);
            return (true, 0, true);
        }
        return (false, 0, false);
    }

    /// @notice card owner (or gateway) cancels redeem by code string
    function cancelRedeem(string calldata code) external nonReentrant {
        _requireOwnerOrGateway();

        address module = _redeemModule();
        (bool ok, bytes memory data) = module.delegatecall(
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.cancelRedeem.selector, code)
        );
        if (!ok) revert UC_RedeemDelegateFailed(data);

        emit RedeemCancelled(keccak256(bytes(code)));
    }

    /// @notice card owner (or gateway) creates a redeem pool (repeatable password; each user once)
    function createRedeemPool(
        bytes32 poolHash,
        uint64 validAfter,
        uint64 validBefore,
        uint256[][] calldata tokenIdsList,
        uint256[][] calldata amountsList,
        uint32[] calldata counts
    ) external nonReentrant {
        _requireOwnerOrGateway();

        address module = _redeemModule();
        (bool ok, bytes memory data) = module.delegatecall(
            abi.encodeWithSelector(
                IBeamioRedeemModuleVNext.createRedeemPool.selector,
                poolHash,
                validAfter,
                validBefore,
                tokenIdsList,
                amountsList,
                counts
            )
        );
        if (!ok) revert UC_RedeemDelegateFailed(data);
    }

    /// @notice card owner (or gateway) terminates pool
    function terminateRedeemPool(bytes32 poolHash) external nonReentrant {
        _requireOwnerOrGateway();

        address module = _redeemModule();
        (bool ok, bytes memory data) = module.delegatecall(
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.terminateRedeemPool.selector, poolHash)
        );
        if (!ok) revert UC_RedeemDelegateFailed(data);
    }

    /// @notice gateway 兑换 redeem（统一处理 one-time 与 pool）
    function redeemByGateway(string calldata code, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        _redeemByGatewayInternal(code, userEOA);
    }

    function _redeemByGatewayInternal(string calldata code, address userEOA) internal {
        if (userEOA == address(0)) revert BM_ZeroAddress();

        address module = _redeemModule();
        (bool ok, bytes memory data) = module.delegatecall(
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeem.selector, code, userEOA)
        );
        if (!ok) revert UC_RedeemDelegateFailed(data);

        (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts) =
            abi.decode(data, (uint256, uint256, uint256[], uint256[]));
        attr; // 未使用的变量
        if (tokenIds.length != amounts.length) revert UC_RedeemDelegateFailed(data);

        address acct = _toAccount(userEOA);

        _syncActiveToBestValid(acct);
        bool hasValidCard = (activeMembershipId[acct] != 0);

        // 避免双倍：当 tokenIds 含 POINTS_ID 时，点数仅取自 bundle；top-level points6 与 bundle 重复会导致双倍 mint
        uint256 totalPoints6 = 0;
        bool pointsInBundle = false;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == POINTS_ID) {
                totalPoints6 += amounts[i];
                pointsInBundle = true;
            }
        }
        if (!pointsInBundle) totalPoints6 = points6;
        if (!hasValidCard && tiers.length > 0) {
            uint256 minReqPoints6 = tiers[tiers.length - 1].minUsdc6;
            if (totalPoints6 < minReqPoints6) revert UC_BelowMinThreshold();
        }

        if (totalPoints6 > 0) _mint(acct, POINTS_ID, totalPoints6, "");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) revert UC_AmountZero();
            if (tokenIds[i] == POINTS_ID) continue; // 已合并到 totalPoints6 一并 mint，避免二次转账
            if (tokenIds[i] >= ISSUED_NFT_START_ID) {
                _mintIssuedNftChecked(acct, tokenIds[i], amt);
            } else {
                _mint(acct, tokenIds[i], amt, "");
            }
        }

        if (!hasValidCard) _issueCardByPointsDelta_AssumingNoValidCard(acct, totalPoints6);
    }

    /// @notice gateway consumes batch one-time redeem (multiple codes of same type) and mints to user's AA account
    function redeemBatchByGateway(string[] calldata codes, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (codes.length == 0) revert UC_InvalidProposal();

        address module = _redeemModule();
        (bool ok, bytes memory data) = module.delegatecall(
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeemBatch.selector, codes, userEOA)
        );
        if (!ok) revert UC_RedeemDelegateFailed(data);

        (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts) =
            abi.decode(data, (uint256, uint256, uint256[], uint256[]));
        attr; // 未使用的变量
        if (tokenIds.length != amounts.length) revert UC_RedeemDelegateFailed(data);

        address acct = _toAccount(userEOA);

        _syncActiveToBestValid(acct);
        bool hasValidCard = (activeMembershipId[acct] != 0);

        // 避免双倍：当 tokenIds 含 POINTS_ID 时，点数仅取自 bundle；top-level points6 与 bundle 重复会导致双倍 mint
        uint256 totalPoints6 = 0;
        bool pointsInBundle = false;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == POINTS_ID) {
                totalPoints6 += amounts[i];
                pointsInBundle = true;
            }
        }
        if (!pointsInBundle) totalPoints6 = points6;
        if (!hasValidCard && tiers.length > 0) {
            uint256 minReqPoints6 = tiers[tiers.length - 1].minUsdc6;
            if (totalPoints6 < minReqPoints6) revert UC_BelowMinThreshold();
        }

        if (totalPoints6 > 0) _mint(acct, POINTS_ID, totalPoints6, "");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) revert UC_AmountZero();
            if (tokenIds[i] == POINTS_ID) continue; // 已合并到 totalPoints6 一并 mint，避免二次转账
            if (tokenIds[i] >= ISSUED_NFT_START_ID) {
                _mintIssuedNftChecked(acct, tokenIds[i], amt);
            } else {
                _mint(acct, tokenIds[i], amt, "");
            }
        }

        if (!hasValidCard) _issueCardByPointsDelta_AssumingNoValidCard(acct, totalPoints6);
    }

    /// @notice gateway 兑换 pool redeem，与 redeemByGateway 共用统一逻辑（自动识别 one-time/pool）
    function redeemPoolByGateway(string calldata code, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        _redeemByGatewayInternal(code, userEOA);
    }

    function _redeemModule() internal view returns (address module) {
        address gw = factoryGateway();
        if (gw == address(0) || gw.code.length == 0) revert UC_GlobalMisconfigured();

        module = IBeamioUserCardFactoryPaymasterV07(gw).defaultRedeemModule();
        if (module == address(0)) revert UC_RedeemModuleZero();
    }

    function _requireOwnerOrGateway() internal view {
        address gw = debugGateway == address(0) ? gateway : debugGateway;
        if (msg.sender != owner() && msg.sender != gw) revert BM_NotAuthorized();
    }

    // ==========================================================
    // Gateway mint (no fund flow; used by FactoryPaymaster after USDC collected)
    // ==========================================================
    /// @notice Gateway 代付 gas 为用户铸 points；资金流由 FactoryPaymaster 处理
    function mintPointsByGateway(address userEOA, uint256 points6) external onlyAuthorizedGateway nonReentrant {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (points6 == 0) revert UC_AmountZero();

        address acct = _toAccount(userEOA);
        _mint(acct, POINTS_ID, points6, "");
        _maybeIssueOnlyIfNoneOrExpiredByPointsDelta(acct, points6);

        emit PointsMintedByGateway(userEOA, acct, points6);
    }

    // ==========================================================
    // Admin minting
    // ==========================================================
    function mintPointsByAdmin(address user, uint256 points6) external nonReentrant {
        _requireOwnerOrGateway();
        if (user == address(0)) revert BM_ZeroAddress();
        if (points6 == 0) revert UC_AmountZero();

        address acct = _toAccount(user);
        _mint(acct, POINTS_ID, points6, "");

        _maybeIssueOnlyIfNoneOrExpiredByPointsDelta(acct, points6);
        emit AdminPointsMinted(acct, points6);
    }

    function _addAdmin(address newAdmin, uint256 newThreshold) internal {
        if (newAdmin == address(0)) revert BM_ZeroAddress();
        if (!isAdmin[newAdmin]) {
            isAdmin[newAdmin] = true;
            adminList.push(newAdmin);
        }
        if (newThreshold > adminList.length) revert UC_InvalidProposal();
        threshold = newThreshold;
    }

    function addAdmin(address newAdmin, uint256 newThreshold) public {
        _requireOwnerOrGateway();
        _addAdmin(newAdmin, newThreshold);
    }

    function _execute(uint256 id) internal {
        Proposal storage p = proposals[id];
        if (p.executed) revert UC_InvalidProposal();
        p.executed = true;

        if (p.selector == bytes4(keccak256("addAdmin(address,uint256)"))) {
            _addAdmin(p.target, p.v1);
        } else if (p.selector == bytes4(keccak256("mintPoints(address,uint256)"))) {
            _mint(p.target, POINTS_ID, p.v1, "");
        } else if (p.selector == bytes4(keccak256("mintMemberCard(address,uint256)"))) {
            _mintMemberCardInternal(p.target, p.v2);
        } else {
            revert UC_InvalidProposal();
        }

        emit ProposalExecuted(id);
    }

    function createProposal(bytes4 selector, address target, uint256 v1, uint256 v2, uint256 v3)
        external
        onlyAuthorizedGateway
        returns (uint256)
    {
        uint256 id = proposalCount++;
        proposals[id] = Proposal(target, v1, v2, v3, selector, 0, false);
        emit ProposalCreated(id, selector, msg.sender);

        if (isAdmin[msg.sender]) _approve(id, msg.sender);
        return id;
    }

    function approveProposalByGateway(uint256 id, address adminSigner) external onlyAuthorizedGateway {
        if (!isAdmin[adminSigner]) revert UC_NotAdmin();
        _approve(id, adminSigner);
    }

    function approveProposal(uint256 id) external onlyAdmin {
        _approve(id, msg.sender);
    }

    function _approve(uint256 id, address admin) internal {
        Proposal storage p = proposals[id];
        if (p.executed) revert UC_InvalidProposal();
        if (isApproved[id][admin]) revert UC_InvalidProposal();

        isApproved[id][admin] = true;
        p.approvals++;
        emit ProposalApproved(id, admin);

        if (p.approvals >= threshold) _execute(id);
    }

    function _setTransferWhitelist(address target, bool allowed) internal {
        transferWhitelist[target] = allowed;
    }

    function setTransferWhitelist(address target, bool allowed) external {
        _requireOwnerOrGateway();
        _setTransferWhitelist(target, allowed);
    }

    function mintMemberCardByAdmin(address user, uint256 tierIndex) external nonReentrant {
        _requireOwnerOrGateway();
        _mintMemberCardInternal(user, tierIndex);
    }

    /// @notice 定义一个新的「发行 NFT」类型（不指定受益人、不 mint）。如：2月3日14:00 门票100张，单价 10 USDC
    /// @param title title 的 bytes32（如 keccak256("Event Name")）
    /// @param validAfter 有效开始时间戳（秒），0=不限制
    /// @param validBefore 有效截止时间戳（秒），0=不限制，须 >= validAfter
    /// @param maxSupply 最大发行数（如 100 张票）
    /// @param priceInCurrency6 单价（card.currency 的 6 位精度），0=免费
    /// @param sharedMetadataHash 系列共享 metadata 的 hash（如 keccak256(ipfs_cid)），0=无；API 用此 hash 从 IPFS 拉取 sharedSeriesMetadata JSON 并与 nftSpecialMetadata 组装
    /// @return tokenId 新创建的 NFT tokenId
    function createIssuedNft(
        bytes32 title,
        uint64 validAfter,
        uint64 validBefore,
        uint256 maxSupply,
        uint256 priceInCurrency6,
        bytes32 sharedMetadataHash
    ) external nonReentrant returns (uint256 tokenId) {
        _requireOwnerOrGateway();
        if (maxSupply == 0) revert UC_AmountZero();
        if (validBefore != 0 && validBefore < validAfter) revert UC_InvalidDateRange(validAfter, validBefore);

        tokenId = _issuedNftIndex++;
        issuedNftTitle[tokenId] = title;
        issuedNftValidAfter[tokenId] = validAfter;
        issuedNftValidBefore[tokenId] = validBefore;
        issuedNftMaxSupply[tokenId] = maxSupply;
        issuedNftPriceInCurrency6[tokenId] = priceInCurrency6;
        issuedNftSharedMetadataHash[tokenId] = sharedMetadataHash;

        emit IssuedNftCreated(tokenId, title, validAfter, validBefore, maxSupply, priceInCurrency6, sharedMetadataHash);
    }

    /// @notice Owner 直接 mint 给受益人（免费，用于分发/兑换等）
    function mintIssuedNftByOwner(address to, uint256 tokenId, uint256 amount) external nonReentrant {
        _requireOwnerOrGateway();
        if (to == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();
        _mintIssuedNftChecked(_toAccount(to), tokenId, amount);
    }

    /// @notice Gateway 为用户 mint（Factory 收 USDC 后调用）
    function mintIssuedNftByGateway(address userEOA, uint256 tokenId, uint256 amount) external onlyAuthorizedGateway nonReentrant {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();
        address acct = _toAccount(userEOA);
        _mintIssuedNftChecked(acct, tokenId, amount);
    }

    function _mintIssuedNftChecked(address acct, uint256 tokenId, uint256 amount) internal {
        if (tokenId < ISSUED_NFT_START_ID) revert UC_InvalidTokenId(tokenId, ISSUED_NFT_START_ID);
        uint256 maxSupply = issuedNftMaxSupply[tokenId];
        if (maxSupply == 0) revert UC_InvalidTokenId(tokenId, 0); // token not defined
        uint256 cnt = issuedNftMintedCount[tokenId];
        if (cnt + amount > maxSupply) revert UC_InsufficientBalance(address(this), tokenId, maxSupply - cnt, amount);
        issuedNftMintedCount[tokenId] = cnt + amount;
        _mint(acct, tokenId, amount, "");
        emit IssuedNftMinted(tokenId, acct, amount);
    }

    /// @notice 当前 issued NFT 的 next tokenId（ISSUED_NFT_START_ID 到 issuedNftIndex()-1 为已定义的 issued NFT）
    function issuedNftIndex() external view returns (uint256) {
        return _issuedNftIndex;
    }

    /// @notice 检查 issued NFT 是否在有效期内
    function isIssuedNftValid(uint256 tokenId) external view returns (bool) {
        if (tokenId < ISSUED_NFT_START_ID) return false;
        uint64 va = issuedNftValidAfter[tokenId];
        uint64 vb = issuedNftValidBefore[tokenId];
        uint256 ts = block.timestamp;
        if (va != 0 && ts < va) return false;
        if (vb != 0 && ts > vb) return false;
        return true;
    }

    function _mintMemberCardInternal(address user, uint256 tierIndex) internal {
        if (user == address(0)) revert BM_ZeroAddress();
        if (tiers.length == 0) revert UC_MustGrow();
        if (tierIndex >= tiers.length) revert UC_MustGrow();

        address acct = _toAccount(user);

        uint256 currentActiveId = activeMembershipId[acct];
        if (currentActiveId != 0 && !_isExpired(currentActiveId)) revert UC_AlreadyHasValidCard();

        uint256 newId = _currentIndex++;
        Tier memory tier = tiers[tierIndex];
        uint256 effExpiry = _effectiveExpirySeconds(tierIndex);

        _mint(acct, newId, 1, "");

        expiresAt[newId] = (effExpiry == 0) ? 0 : (block.timestamp + effExpiry);
        attributes[newId] = tier.attr;
        tokenTierIndexOrMax[newId] = tierIndex;
        _userOwnedNfts[acct].push(newId);
        activeMembershipId[acct] = newId;
        activeTierIndexOrMax[acct] = tierIndex;

        emit AdminCardMinted(acct, newId, tier.attr, expiresAt[newId]);
    }

    // ==========================================================
    // ERC1155 update hook
    // ==========================================================
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        bool isRealTransfer = (from != address(0) && to != address(0));

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];

            if (id >= NFT_START_ID && id < ISSUED_NFT_START_ID) {
                if (!(from == address(0) || to == address(0))) revert UC_SBTNonTransferable();
                if (to == address(0) && from != address(0)) _removeNft(from, id);
                continue;
            }

            if (id == POINTS_ID && isRealTransfer) {
                // 模式1：白名单开启 -> 限制 to
                if (transferWhitelistEnabled) {
                    // transferWhitelist[address(0)] == true 表示"白名单全开放"（你原本的语义）
                    if (!transferWhitelist[address(0)]) {
                        if (!transferWhitelist[to]) revert UC_PointsToNotWhitelisted();
                    }
                }

                // 模式2：白名单关闭 -> 完全不限制（允许 EOA / 任意合约）
            }
        }

        super._update(from, to, ids, values);
    }

    function _removeNft(address user, uint256 id) internal {
        uint256[] storage list = _userOwnedNfts[user];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == id) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        if (activeMembershipId[user] == id) {
            activeMembershipId[user] = 0;
            activeTierIndexOrMax[user] = type(uint256).max;
        }
    }

    // ==========================================================
    // Views
    // ==========================================================
    function getOwnership(address user) public view returns (uint256 pt, NFTDetail[] memory nfts) {
        uint256[] storage nftIds = _userOwnedNfts[user];
        nfts = new NFTDetail[](nftIds.length);

        for (uint256 i = 0; i < nftIds.length; i++) {
            uint256 id = nftIds[i];
            uint256 exp = expiresAt[id];
            bool expired = (exp != 0 && block.timestamp > exp);
            nfts[i] = NFTDetail(id, attributes[id], tokenTierIndexOrMax[id], exp, expired);
        }

        return (balanceOf(user, POINTS_ID), nfts);
    }

    function getOwnershipByEOA(address userEOA) external view returns (uint256 pt, NFTDetail[] memory nfts) {
        address acct = _resolveAccount(userEOA);
        return getOwnership(acct);
    }

    // ==========================================================
    // Membership helpers
    // ==========================================================
    function _tierMinPoints6(uint256 i) internal view returns (uint256) { return tiers[i].minUsdc6; }

    /// @dev Returns effective expiry seconds for a tier: tier.tierExpirySeconds if > 0, else global expirySeconds.
    function _effectiveExpirySeconds(uint256 tierIndex) internal view returns (uint256) {
        uint256 ts = tiers[tierIndex].tierExpirySeconds;
        return ts > 0 ? ts : expirySeconds;
    }

    function _isExpired(uint256 tokenId) internal view returns (bool) {
        uint256 exp = expiresAt[tokenId];
        return (exp != 0 && block.timestamp > exp);
    }

    function _hasValidCard(address acct) internal view returns (bool) {
        uint256 id = activeMembershipId[acct];
        return (id != 0 && balanceOf(acct, id) > 0 && !_isExpired(id));
    }

    function _syncAndHasValidCard(address acct) internal returns (bool) {
        _syncActiveToBestValid(acct);
        return _hasValidCard(acct);
    }

    function _syncActiveToBestValid(address user) internal {
        uint256 cur = activeMembershipId[user];
        if (cur != 0) {
            if (balanceOf(user, cur) > 0 && !_isExpired(cur)) {
                activeTierIndexOrMax[user] = tokenTierIndexOrMax[cur];
                return;
            }
        }

        uint256[] storage nftIds = _userOwnedNfts[user];
        if (nftIds.length == 0) {
            activeMembershipId[user] = 0;
            activeTierIndexOrMax[user] = type(uint256).max;
            return;
        }

        uint256 bestId = 0;
        uint256 bestTierIndex = type(uint256).max;

        for (uint256 i = 0; i < nftIds.length; i++) {
            uint256 id = nftIds[i];
            if (balanceOf(user, id) == 0) continue;
            if (_isExpired(id)) continue;

            uint256 tierIdx = tokenTierIndexOrMax[id];
            if (tierIdx < bestTierIndex) {
                bestId = id;
                bestTierIndex = tierIdx;
            }
        }

        activeMembershipId[user] = bestId;
        activeTierIndexOrMax[user] = bestTierIndex;
    }

    function _maybeIssueOnlyIfNoneOrExpiredByPointsDelta(address acctOrEOA, uint256 pointsDelta6) internal {
        address acct = _toAccount(acctOrEOA);
        _syncActiveToBestValid(acct);

        if (activeMembershipId[acct] != 0) return;

        if (tiers.length == 0) {
            uint256 expiry = (expirySeconds == 0) ? 0 : (block.timestamp + expirySeconds);
            uint256 newId = _currentIndex++;

            _mint(acct, newId, 1, "");

            expiresAt[newId] = expiry;
            attributes[newId] = defaultAttrWhenNoTiers;
            tokenTierIndexOrMax[newId] = type(uint256).max;
            _userOwnedNfts[acct].push(newId);

            emit MemberNFTIssued(acct, newId, type(uint256).max, 0, expiry);

            activeMembershipId[acct] = newId;
            activeTierIndexOrMax[acct] = type(uint256).max;
            return;
        }

        uint256 tierIdx = type(uint256).max;
        uint256 attr = 0;

        for (uint256 i = 0; i < tiers.length; i++) {
            if (pointsDelta6 >= _tierMinPoints6(i)) {
                tierIdx = i;
                attr = tiers[i].attr;
                break;
            }
        }
        if (tierIdx == type(uint256).max) return;

        uint256 effExpiry = _effectiveExpirySeconds(tierIdx);
        uint256 expiry2 = (effExpiry == 0) ? 0 : (block.timestamp + effExpiry);
        uint256 newId2 = _currentIndex++;

        _mint(acct, newId2, 1, "");

        expiresAt[newId2] = expiry2;
        attributes[newId2] = attr;
        tokenTierIndexOrMax[newId2] = tierIdx;
        _userOwnedNfts[acct].push(newId2);

        emit MemberNFTIssued(acct, newId2, tierIdx, tiers[tierIdx].minUsdc6, expiry2);

        activeMembershipId[acct] = newId2;
        activeTierIndexOrMax[acct] = tierIdx;
    }

    function _issueCardByPointsDelta_AssumingNoValidCard(address acct, uint256 pointsDelta6) internal {
        if (activeMembershipId[acct] != 0) revert UC_AlreadyHasValidCard();

        if (tiers.length == 0) {
            uint256 expiry = (expirySeconds == 0) ? 0 : (block.timestamp + expirySeconds);
            uint256 newId = _currentIndex++;

            _mint(acct, newId, 1, "");

            expiresAt[newId] = expiry;
            attributes[newId] = defaultAttrWhenNoTiers;
            tokenTierIndexOrMax[newId] = type(uint256).max;
            _userOwnedNfts[acct].push(newId);

            emit MemberNFTIssued(acct, newId, type(uint256).max, 0, expiry);

            activeMembershipId[acct] = newId;
            activeTierIndexOrMax[acct] = type(uint256).max;
            return;
        }

        uint256 tierIdx = type(uint256).max;
        uint256 attr = 0;

        for (uint256 i = 0; i < tiers.length; i++) {
            if (pointsDelta6 >= tiers[i].minUsdc6) {
                tierIdx = i;
                attr = tiers[i].attr;
                break;
            }
        }
        if (tierIdx == type(uint256).max) return;

        uint256 effExpiry = _effectiveExpirySeconds(tierIdx);
        uint256 expiry2 = (effExpiry == 0) ? 0 : (block.timestamp + effExpiry);
        uint256 newId2 = _currentIndex++;

        _mint(acct, newId2, 1, "");

        expiresAt[newId2] = expiry2;
        attributes[newId2] = attr;
        tokenTierIndexOrMax[newId2] = tierIdx;
        _userOwnedNfts[acct].push(newId2);

        emit MemberNFTIssued(acct, newId2, tierIdx, tiers[tierIdx].minUsdc6, expiry2);

        activeMembershipId[acct] = newId2;
        activeTierIndexOrMax[acct] = tierIdx;
    }

    // ==========================================================
    // AA account resolve
    // ==========================================================
    function _toAccount(address maybeEoaOrAcct) internal view returns (address acct) {
        address f = IBeamioFactoryOracle(factoryGateway()).aaFactory();
        if (f == address(0)) revert UC_GlobalMisconfigured();

        if (IBeamioAccountFactoryV07(f).isBeamioAccount(maybeEoaOrAcct)) {
            if (maybeEoaOrAcct.code.length == 0) revert UC_NoBeamioAccount();
            return maybeEoaOrAcct;
        }
        return _resolveAccount(maybeEoaOrAcct);
    }

    function _resolveAccount(address eoa) internal view returns (address) {
        address aaFactory = IBeamioGatewayAAFactoryGetter(factoryGateway())._aaFactory();
        if (aaFactory == address(0)) revert UC_GlobalMisconfigured();

        address acct = IBeamioAccountFactoryV07(aaFactory).beamioAccountOf(eoa);
        if (acct == address(0) || acct.code.length == 0) revert UC_ResolveAccountFailed(eoa, aaFactory, acct);
        return acct;
    }
}
