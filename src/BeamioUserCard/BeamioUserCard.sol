// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioERC1155Logic.sol";
import "./BeamioCurrency.sol";
import "./Errors.sol";
import "./RedeemStorage.sol";
import "./FaucetStorage.sol";
import "./IssuedNftStorage.sol";
import "./GovernanceStorage.sol";
import "./MembershipStatsStorage.sol";
import "./TotalSupplyStorage.sol";
import "./AdminStatsStorage.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardTypes.sol";
import "./BeamioUserCardFormattingLib.sol";
import "./BeamioUserCardTransferLib.sol";

import "../contracts/token/ERC1155/ERC1155.sol";
import "../contracts/access/Ownable.sol";
import "../contracts/utils/ReentrancyGuard.sol";

// 注意：IBeamioFactoryOracle, IBeamioAccountFactoryV07 已在 BeamioERC1155Logic.sol 中定义（资金流已移至 Factory）
// 其余模块 interface 见 BeamioUserCardInterfaces.sol

/* =========================================================
   BeamioUserCard
   ========================================================= */

contract BeamioUserCard is ERC1155, Ownable, ReentrancyGuard {
    using BeamioCurrency for *;

    // ===== Versioning =====
    uint256 public constant VERSION = 20;

    // ===== Constants (no magic numbers) =====
    uint256 public constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint8 public constant POINTS_DECIMALS = BeamioERC1155Logic.POINTS_DECIMALS;
    uint256 private constant POINTS_ONE = 10 ** uint256(POINTS_DECIMALS);

    uint256 public constant NFT_START_ID = BeamioERC1155Logic.NFT_START_ID;
    uint256 public constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;
    uint8 private constant MODULE_REDEEM = 0;
    uint8 private constant MODULE_FAUCET = 1;
    uint8 private constant MODULE_ISSUED_NFT = 2;
    uint8 private constant MODULE_GOVERNANCE = 3;
    uint8 private constant MODULE_MEMBERSHIP_STATS = 4;
    uint8 private constant ROUTE_STATS_QUERY = type(uint8).max - 1;

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

    // ===== multisig governance (storage in GovernanceStorage; views below) =====
    event ProposalCreated(uint256 indexed id, bytes4 indexed selector, address indexed proposer);
    event ProposalApproved(uint256 indexed id, address indexed admin);
    event ProposalExecuted(uint256 indexed id);

    modifier onlyAdmin() {
        if (!GovernanceStorage.layout().isAdmin[msg.sender]) revert UC_NotAdmin();
        _;
    }

    // ===== whitelist =====
    mapping(address => bool) public transferWhitelist;
    bool public transferWhitelistEnabled;
    event TransferWhitelistEnabledUpdated(bool enabled);

    // ===== Faucet (storage in FaucetStorage; views below) =====
    event FaucetConfigUpdated(uint256 indexed id, FaucetStorage.FaucetConfig cfg);
    event FaucetClaimed(uint256 indexed id, address indexed userEOA, address indexed acct, uint256 amount, uint256 claimedAfter);

    // ===== Issued NFT (storage in IssuedNftStorage; views below) =====
    event IssuedNftCreated(uint256 indexed tokenId, bytes32 title, uint64 validAfter, uint64 validBefore, uint256 maxSupply, uint256 priceInCurrency6, bytes32 sharedMetadataHash);
    event IssuedNftMinted(uint256 indexed tokenId, address indexed recipient, uint256 amount);

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
    mapping(uint256 => uint256) public activeMembershipCountByTokenId;
    mapping(uint256 => uint256) public activeMembershipCountByTierIndex;
    /// @dev 已累计发行的会员 NFT 总数（业务上「已发行会员卡」数量以本计数为准；链上增量 tokenId 见 `_currentIndex` 分配语义）。
    uint256 public totalMembershipIssued;
    uint256 public totalMembershipUpgraded;
    uint256 public totalActiveMemberships;
    mapping(uint256 => uint256) public totalMembershipIssuedByTierIndex;

    struct NFTDetail {
        uint256 tokenId;
        uint256 attribute;
        uint256 tierIndexOrMax;
        uint256 expiry;
        bool isExpired;
    }

    /// @notice Points 转账白名单（供 BeamioUserCardTransferLib delegatecall 路径查询）
    function isPointsTransferRecipientAllowed(address effectiveTo) external view returns (bool) {
        if (!transferWhitelistEnabled) return true;
        return transferWhitelist[address(0)] || transferWhitelist[effectiveTo];
    }

    // ===== tiers (struct Tier in BeamioUserCardTypes.sol) =====
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
    event AdminPointsBurned(address indexed account, uint256 amount);
    event PointsMintedByGateway(address indexed userEOA, address indexed acct, uint256 points6);

    // ===== current index (membership NFT; issued NFT index in IssuedNftStorage) =====
    /// @dev 下一枚会员档 NFT 将使用的 tokenId，自 `NFT_START_ID`（100）起单调递增；区间为 [NFT_START_ID, ISSUED_NFT_START_ID)，之后为 issued 系列 ID 空间。
    uint256 private _currentIndex = NFT_START_ID;

    /// @dev 与 BeamioUserCardBase 同序，供 MembershipStatsModule delegatecall 一致
    uint8 public upgradeType;

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
        address gateway_,
        uint8 upgradeType_,
        bool initialTransferWhitelistEnabled
    ) ERC1155("") Ownable(initialOwner) {
        if (initialOwner == address(0)) revert BM_ZeroAddress();
        if (gateway_ == address(0) || gateway_.code.length == 0) revert UC_GlobalMisconfigured();
        if (upgradeType_ > 2) revert UC_InvalidUpgradeType();

        deployer = msg.sender;
        gateway = gateway_;
        debugGateway = gateway_;
        uri_; // kept for constructor ABI compatibility; metadata base URI is shared in factory

        currency = currency_;
        pointsUnitPriceInCurrencyE6 = pointsUnitPriceInCurrencyE6_;
        upgradeType = upgradeType_;

        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        g.threshold = 1;
        g.isAdmin[initialOwner] = true;
        g.adminList.push(initialOwner);

        IssuedNftStorage.Layout storage inft = IssuedNftStorage.layout();
        inft.issuedNftIndex = ISSUED_NFT_START_ID;

        if (initialTransferWhitelistEnabled) {
            _setTransferWhitelistEnabled(true);
        }
    }

    /// @notice Base Explorer / EIP-1155 约定：base URI 前缀 + 0x{合约地址}{id}.json，{id} 由客户端替换为 tokenId（64 位十六进制）
    function uri(uint256) public view override returns (string memory) {
        return BeamioUserCardFormattingLib.buildErc1155MetadataUri(_metadataBaseURI(), address(this));
    }

    function metadataBaseURI() external view returns (string memory) {
        return _metadataBaseURI();
    }

    function _metadataBaseURI() internal view returns (string memory) {
        address gw = factoryGateway();
        if (gw == address(0) || gw.code.length == 0) revert UC_GlobalMisconfigured();
        string memory baseURI = IBeamioUserCardFactoryPaymasterV07(gw).metadataBaseURI();
        if (bytes(baseURI).length == 0) revert UC_GlobalMisconfigured();
        return baseURI;
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
        uint256 idx = tiers.length;
        tiers.push(Tier(minUsdc6, attr, tierExpirySeconds));
        emit TierAppended(idx, minUsdc6, attr, tierExpirySeconds);
    }

    function setTiers(Tier[] calldata newTiers) external {
        _requireOwnerOrGateway();
        if (newTiers.length == 0) revert UC_TierLenMismatch();
        for (uint256 i = 0; i < newTiers.length; i++) {
            if (newTiers[i].minUsdc6 == 0) revert UC_TierMinZero();
        }
        delete tiers;
        for (uint256 i = 0; i < newTiers.length; i++) tiers.push(newTiers[i]);
        emit TiersUpdated(newTiers.length);
    }

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

    function faucetConfig(uint256 id) external view returns (FaucetStorage.FaucetConfig memory) {
        return FaucetStorage.layout().faucetConfig[id];
    }

    function issuedNftPriceInCurrency6(uint256 tokenId) external view returns (uint256) {
        return IssuedNftStorage.layout().issuedNftPriceInCurrency6[tokenId];
    }

    function isAdmin(address a) external view returns (bool) { return GovernanceStorage.layout().isAdmin[a]; }
    /// @notice 查询 admin 的 parent（谁添加了该 admin；owner 添加的为 address(0)）
    function adminParent(address a) external view returns (address) {
        return GovernanceStorage.layout().adminParent[a];
    }

    // ==========================================================
    // Faucet config (delegatecall)
    // ==========================================================
    function _revertDelegate(bytes memory data) internal pure {
        if (data.length > 0) assembly { revert(add(data, 32), mload(data)) }
        revert UC_RedeemDelegateFailed(data);
    }

    // ==========================================================
    // Faucet (free) — delegatecall validate then mint
    // ==========================================================
    function faucetByGateway(address userEOA, uint256 id, uint256 amount)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();

        bytes memory data = _callModule(
            MODULE_FAUCET,
            abi.encodeWithSelector(IBeamioFaucetModuleV1.validateAndRecordFreeFaucet.selector, userEOA, id, amount)
        );
        (uint256 outId, uint256 outAmount) = abi.decode(data, (uint256, uint256));

        address acct = _toAccount(userEOA);
        _syncActiveToBestValid(acct);
        bool hadValidCard = _hasValidCard(acct);
        if (outId == POINTS_ID && outAmount > 0) {
            _requirePointsMintAllowsFirstMembership(acct, outAmount);
        }
        _mint(acct, outId, outAmount, "");
        uint256 pointsDelta6 = (outId == POINTS_ID) ? outAmount : 0;
        (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
        if (!hadValidCard) {
            if (tiers.length == 0) {
                _issueCardByPointsDelta_AssumingNoValidCard(acct, pointsDelta6);
            } else if (pointsDelta6 > 0) {
                _issueCardByPointsDelta_AssumingNoValidCard(acct, pointsDelta6);
            }
        } else if (pointsDelta6 > 0) {
            _maybeUpgrade(acct, pointsDelta6);
        }
        _recordAdminMembershipFlowForOperatorAndParents(owner(), issuedBefore, upgradedBefore);
        emit FaucetClaimed(outId, userEOA, acct, outAmount, FaucetStorage.layout().faucetClaimed[outId][userEOA]);
    }

    /// @notice Gateway mint for paid faucet；资金流由 FactoryPaymaster.purchaseFaucetForUser 处理
    /// @dev 与 mintPointsByGateway 一致：mint 后需触发会员发卡/升级，否则 totalActiveMemberships 不更新
    function mintFaucetByGateway(address userEOA, uint256 id, uint256 amount6) external onlyAuthorizedGateway nonReentrant {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount6 == 0) revert UC_AmountZero();

        bytes memory data = _callModule(
            MODULE_FAUCET,
            abi.encodeWithSelector(IBeamioFaucetModuleV1.validateAndRecordPaidFaucet.selector, userEOA, id, amount6)
        );
        (uint256 outId, uint256 outAmount) = abi.decode(data, (uint256, uint256));

        address acct = _toAccount(userEOA);
        _syncActiveToBestValid(acct);
        if (outId == POINTS_ID && outAmount > 0) {
            _requirePointsMintAllowsFirstMembership(acct, outAmount);
        }
        _mint(acct, outId, outAmount, "");
        uint256 pointsDelta6 = (outId == POINTS_ID) ? outAmount : 0;
        if (pointsDelta6 > 0) {
            (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
            _maybeIssueOnlyIfNoneOrExpiredByPointsDelta(acct, pointsDelta6);
            _maybeUpgrade(acct, pointsDelta6);
            _recordAdminMembershipFlowForOperatorAndParents(owner(), issuedBefore, upgradedBefore);
        }
        emit FaucetClaimed(outId, userEOA, acct, outAmount, FaucetStorage.layout().faucetClaimed[outId][userEOA]);
    }

    // ==========================================================
    // Redeem suite (owner issues; gateway consumes)
    // ==========================================================

    /// @notice gateway 兑换 redeem-admin：用户提供秘密 code，匹配合格后添加 to 为 admin
    function redeemAdminByGateway(string calldata code, address to) external onlyAuthorizedGateway nonReentrant {
        if (to == address(0)) revert BM_ZeroAddress();
        bytes memory out = _callModule(
            MODULE_REDEEM,
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeemAdmin.selector, code)
        );
        (string memory metadata, uint256 mintLimit) = abi.decode(out, (string, uint256));
        address module = _module(MODULE_GOVERNANCE);
        uint256 newThreshold = 1; // redeem 添加的 admin 使用 threshold=1
        bool ok;
        if (mintLimit > 0) {
            (ok,) = module.delegatecall(
                abi.encodeWithSelector(
                    bytes4(keccak256("adminManager(address,bool,uint256,string,uint256)")),
                    to,
                    true,
                    newThreshold,
                    metadata,
                    mintLimit
                )
            );
        } else {
            (ok,) = module.delegatecall(
                abi.encodeWithSelector(
                    bytes4(keccak256("adminManager(address,bool,uint256,string)")),
                    to,
                    true,
                    newThreshold,
                    metadata
                )
            );
        }
        if (!ok) revert UC_InvalidProposal();
    }

    function _getRedeemCreatorAndRecommender(string calldata code)
        internal
        view
        returns (address creator, address recommender)
    {
        return BeamioUserCardTransferLib.getRedeemCreatorAndRecommender(code);
    }

    /// @dev redeemByGateway / redeemBatchByGateway 共用：module 返回解码后的 bundle 铸币与会员流
    function _applyRedeemBundleToUser(
        address userEOA,
        address creator,
        address recommender,
        uint256 points6,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        bytes memory redeemErrCtx
    ) internal {
        if (tokenIds.length != amounts.length) revert UC_RedeemDelegateFailed(redeemErrCtx);

        address acct = _toAccount(userEOA);
        _syncActiveToBestValid(acct);
        bool hasValidCard = _hasValidCard(acct);

        uint256 totalPoints6 = 0;
        bool pointsInBundle = false;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == POINTS_ID) {
                totalPoints6 += amounts[i];
                pointsInBundle = true;
            }
        }
        if (!pointsInBundle) totalPoints6 = points6;

        if (totalPoints6 > 0) {
            _requirePointsMintAllowsFirstMembership(acct, totalPoints6);
            _mint(acct, POINTS_ID, totalPoints6, "");
            AdminStatsStorage.recordMint(creator != address(0) ? creator : owner(), totalPoints6);
            _recordAdminRedeemMintForOperatorAndParents(recommender, totalPoints6);
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) revert UC_AmountZero();
            if (tokenIds[i] == POINTS_ID) continue;
            if (tokenIds[i] >= ISSUED_NFT_START_ID) {
                _mintIssuedNftChecked(acct, tokenIds[i], amt);
            } else {
                _mint(acct, tokenIds[i], amt, "");
            }
        }

        address statsOperator = creator != address(0) ? creator : owner();
        (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
        if (!hasValidCard) _issueCardByPointsDelta_AssumingNoValidCard(acct, totalPoints6);
        else _maybeUpgrade(acct, totalPoints6);
        _recordAdminMembershipFlowForOperatorAndParents(statsOperator, issuedBefore, upgradedBefore);
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
        (address creator, address recommender) = _getRedeemCreatorAndRecommender(code);
        bytes memory data = _callModule(
            MODULE_REDEEM,
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeem.selector, code, userEOA)
        );
        (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts) =
            abi.decode(data, (uint256, uint256, uint256[], uint256[]));
        attr;
        _applyRedeemBundleToUser(userEOA, creator, recommender, points6, tokenIds, amounts, data);
    }

    /// @notice gateway consumes batch one-time redeem (multiple codes of same type) and mints to user's AA account
    function redeemBatchByGateway(string[] calldata codes, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (codes.length == 0) revert UC_InvalidProposal();
        (address creator, address recommender) =
            codes.length > 0 ? _getRedeemCreatorAndRecommender(codes[0]) : (address(0), address(0));
        bytes memory data = _callModule(
            MODULE_REDEEM,
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeemBatch.selector, codes, userEOA)
        );
        (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts) =
            abi.decode(data, (uint256, uint256, uint256[], uint256[]));
        attr;
        _applyRedeemBundleToUser(userEOA, creator, recommender, points6, tokenIds, amounts, data);
    }

    /// @notice gateway 兑换 pool redeem，与 redeemByGateway 共用统一逻辑（自动识别 one-time/pool）
    function redeemPoolByGateway(string calldata code, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        _redeemByGatewayInternal(code, userEOA);
    }

    function _module(uint8 moduleKind) internal view returns (address module) {
        address gw = factoryGateway();
        if (gw == address(0) || gw.code.length == 0) revert UC_GlobalMisconfigured();
        IBeamioUserCardFactoryPaymasterV07 f = IBeamioUserCardFactoryPaymasterV07(gw);
        if (moduleKind == MODULE_REDEEM) module = f.defaultRedeemModule();
        else if (moduleKind == MODULE_FAUCET) module = f.defaultFaucetModule();
        else if (moduleKind == MODULE_ISSUED_NFT) module = f.defaultIssuedNftModule();
        else if (moduleKind == MODULE_GOVERNANCE) module = f.defaultGovernanceModule();
        else module = f.defaultMembershipStatsModule();
        if (module != address(0)) return module;
        if (moduleKind == MODULE_MEMBERSHIP_STATS) revert UC_StatsModuleZero();
        revert UC_RedeemModuleZero();
    }

    function _callModule(uint8 moduleKind, bytes memory data) internal returns (bytes memory ret) {
        (bool ok, bytes memory out) = _module(moduleKind).delegatecall(data);
        ret = out;
        if (!ok) _revertDelegate(ret);
    }

    function _statsQueryModule() internal view returns (address module) {
        address gw = factoryGateway();
        if (gw == address(0) || gw.code.length == 0) revert UC_GlobalMisconfigured();
        module = IBeamioUserCardFactoryPaymasterV07(gw).defaultAdminStatsQueryModule();
        if (module == address(0) || module.code.length == 0) revert UC_GlobalMisconfigured();
    }

    fallback() external {
        address statsModule = _statsQueryModule();
        uint8 route = IBeamioUserCardSelectorRouter(statsModule).selectorModuleKind(msg.sig);
        address module;
        if (route == ROUTE_STATS_QUERY) module = statsModule;
        else if (route == MODULE_REDEEM) module = _module(MODULE_REDEEM);
        else if (route == MODULE_GOVERNANCE) module = _module(MODULE_GOVERNANCE);
        else if (route == MODULE_FAUCET) module = _module(MODULE_FAUCET);
        else if (route == MODULE_ISSUED_NFT) module = _module(MODULE_ISSUED_NFT);
        else revert BM_CallFailed();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(0, 0, size)
            switch ok
            case 0 { revert(0, size) }
            default { return(0, size) }
        }
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
        _mintPointsByGatewayWithOperator(userEOA, points6, owner());
    }

    /// @notice Gateway 代付 gas 为用户铸 points；operator 可为 recommender admin 或 owner
    function mintPointsByGatewayWithOperator(address userEOA, uint256 points6, address operator)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        _mintPointsByGatewayWithOperator(userEOA, points6, operator);
    }

    /// @notice Open-container USDC→topup path: only factory-configured executor; same mint/stats as gateway mint.
    /// @param payerAA BeamioAccount that pays USDC and receives minted points (token #0).
    /// @param operatorForStats infrastructure card `owner()` passed from module for admin USDC mint counters.
    function mintPointsOpenContainerRelay(address payerAA, uint256 points6, address operatorForStats)
        external
        nonReentrant
    {
        if (points6 == 0) return;
        if (payerAA == address(0)) revert BM_ZeroAddress();
        if (operatorForStats == address(0)) revert BM_ZeroAddress();

        address f = IBeamioAccountViewForOpenRelay(payerAA).factory();
        if (f == address(0)) revert BM_ZeroAddress();

        address exec = IBeamioFactoryOpenRelayViews(f).openContainerMintExecutor();
        if (exec == address(0)) revert UC_GlobalMisconfigured();
        if (msg.sender != exec) revert UC_OpenMintExecutorUnauthorized();
        if (!IBeamioFactoryOpenRelayViews(f).isBeamioAccount(payerAA)) revert UC_NoBeamioAccount();

        address userEOA = IBeamioAccountViewForOpenRelay(payerAA).owner();
        _mintPointsByGatewayWithOperator(userEOA, points6, operatorForStats);
    }

    function _mintPointsByGatewayWithOperator(address userEOA, uint256 points6, address operator) internal {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (operator == address(0)) revert BM_ZeroAddress();
        if (points6 == 0) revert UC_AmountZero();

        address acct = _toAccount(userEOA);
        _syncActiveToBestValid(acct);
        _requirePointsMintAllowsFirstMembership(acct, points6);
        (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
        _mint(acct, POINTS_ID, points6, "");
        _maybeIssueOnlyIfNoneOrExpiredByPointsDelta(acct, points6);
        _maybeUpgrade(acct, points6);
        _recordAdminUSDCMintForOperatorAndParents(operator, points6);
        _recordAdminMembershipFlowForOperatorAndParents(operator, issuedBefore, upgradedBefore);

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
        _syncActiveToBestValid(acct);
        _requirePointsMintAllowsFirstMembership(acct, points6);
        (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
        _mint(acct, POINTS_ID, points6, "");

        _maybeIssueOnlyIfNoneOrExpiredByPointsDelta(acct, points6);
        _maybeUpgrade(acct, points6);
        _recordAdminMembershipFlowForOperatorAndParents(owner(), issuedBefore, upgradedBefore);
        emit AdminPointsMinted(acct, points6);
    }

    /// @notice Admin 离线签字后经 gateway 执行；operator 为签名 admin，自身及 parent 链记账
    function mintPointsByAdminWithOperator(address user, uint256 points6, address operator)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        if (user == address(0) || operator == address(0)) revert BM_ZeroAddress();
        if (points6 == 0) revert UC_AmountZero();
        if (!GovernanceStorage.layout().isAdmin[operator]) revert UC_NotAdmin();
        _callModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.enforceAndRecordAdminAirdropLimit.selector, operator, points6)
        );

        address acct = _toAccount(user);
        _syncActiveToBestValid(acct);
        _requirePointsMintAllowsFirstMembership(acct, points6);
        (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
        _mint(acct, POINTS_ID, points6, "");
        AdminStatsStorage.recordMint(operator, points6);
        _maybeIssueOnlyIfNoneOrExpiredByPointsDelta(acct, points6);
        _maybeUpgrade(acct, points6);
        _recordAdminMembershipFlowForOperatorAndParents(operator, issuedBefore, upgradedBefore);
        emit AdminPointsMinted(acct, points6);
    }

    /// @notice Admin 离线签字授权 burn 某一地址的 token 0；仅 gateway 调用，Factory executeForAdmin 验签后执行
    /// @param target 被 burn 的地址（EOA 或 AA）；signer 必须为 card admin
    /// @param amount 销毁数量；type(uint256).max 表示 burn 全部
    function burnPointsByAdmin(address target, uint256 amount) external onlyAuthorizedGateway nonReentrant {
        if (target == address(0)) revert BM_ZeroAddress();
        address acct = _toAccount(target);
        uint256 bal = balanceOf(acct, POINTS_ID);
        if (bal == 0) revert UC_AmountZero();
        if (amount == type(uint256).max) amount = bal;
        if (amount > bal) revert UC_InsufficientBalance(acct, POINTS_ID, bal, amount);
        if (amount == 0) revert UC_AmountZero();

        _burn(acct, POINTS_ID, amount);
        emit AdminPointsBurned(acct, amount);
    }

    /// @notice 记录 admin burn 统计（仅 gateway 调用，Factory 在 burnPointsByAdmin 成功后调用，operator 为 signer）
    function recordAdminBurnForStats(address operator, uint256 amount) external onlyAuthorizedGateway {
        AdminStatsStorage.recordBurn(operator, amount);
    }

    /// @notice 记录 admin mint 统计（仅 gateway 调用，Factory 在 mintPointsByAdmin 成功后调用）
    function recordAdminMintForStats(address admin, uint256 amount) external onlyAuthorizedGateway {
        AdminStatsStorage.recordMint(admin, amount);
    }

    /// @notice 查询 admin 累计 mint 计数（从上次 clear 起）
    function getAdminMintCounter(address admin) external view returns (uint256) {
        return AdminStatsStorage.layout().adminMintCounter[admin];
    }

    /// @notice 查询 admin 累计 burn 计数（从上次 clear 起）
    function getAdminBurnCounter(address admin) external view returns (uint256) {
        return AdminStatsStorage.layout().adminBurnCounter[admin];
    }

    /// @notice 查询 admin 累计 transfer 次数（从上次 clear 起）
    function getAdminTransferCounter(address admin) external view returns (uint256) {
        return AdminStatsStorage.layout().adminTransferCounter[admin];
    }

    /// @notice 查询 admin 累计 transfer 金额（从上次 clear 起）
    function getAdminTransferAmountCounter(address admin) external view returns (uint256) {
        return AdminStatsStorage.layout().adminTransferAmountCounter[admin];
    }

    /// @notice 查询 admin redeem 完成后单独累计的 mint 计数（从上次 clear 起）
    function getAdminRedeemMintCounter(address admin) external view returns (uint256) {
        return AdminStatsStorage.layout().adminRedeemMintCounter[admin];
    }

    /// @notice 查询 admin USDC topup 完成后单独累计的 mint 计数（从上次 clear 起）
    function getAdminUSDCMintCounter(address admin) external view returns (uint256) {
        return AdminStatsStorage.layout().adminUSDCMintCounter[admin];
    }

    /// @notice parent admin 清零 subordinate 的 mint/burn/transfer 计数（仅 gateway 调用，Factory executeForAdmin 支持）
    /// @param subordinate 被清零的 admin
    /// @param authorizer 必须等于 adminParent[subordinate]，即 parent；Factory 验签后传入 signer
    function clearAdminMintCounterForSubordinate(address subordinate, address authorizer) external onlyAuthorizedGateway {
        _callModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(
                IBeamioGovernanceModuleV1.clearAdminStatsAndAirdropUsageForSubordinate.selector,
                subordinate,
                authorizer
            )
        );
    }

    /// @notice Owner 离线签字后经 gateway 的 executeForOwner 执行。仅清零 adminAddr 的 topup 相关计数（adminRedeemMintCounter、adminUSDCMintCounter），恢复 mintLimitPoints6 预定的 topup 额度。
    function resetAdminLimit(address adminAddr) external onlyAuthorizedGateway {
        _callModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.resetAdminLimit.selector, adminAddr)
        );
    }

    /// @notice Admin 离线签字后经 gateway 的 executeForAdmin 执行。仅 adminParent[adminAddr] 可重置 subordinate，admin 自身无自重置权限。
    function resetAdminLimitByAdmin(address adminAddr, address authorizer) external onlyAuthorizedGateway {
        _callModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.resetAdminLimitByAdmin.selector, adminAddr, authorizer)
        );
    }

    function _executeWith(bytes4 sel, address target, uint256 v1, uint256 v2, uint256 /* v3 */) internal {
        if (sel == bytes4(keccak256("adminManager(address,bool,uint256,string)"))) {
            revert UC_AdminManagerRequiresOwnerSignature();
        } else if (sel == bytes4(keccak256("mintPoints(address,uint256)"))) {
            _mint(target, POINTS_ID, v1, "");
        } else if (sel == bytes4(keccak256("mintMemberCard(address,uint256)"))) {
            _mintMemberCardInternal(target, v2);
        } else {
            revert UC_InvalidProposal();
        }
    }

    function createProposal(bytes4 selector, address target, uint256 v1, uint256 v2, uint256 v3)
        external
        onlyAuthorizedGateway
        returns (uint256)
    {
        address module = _module(MODULE_GOVERNANCE);
        bytes memory data = _callModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.createProposal.selector, selector, target, v1, v2, v3)
        );
        uint256 id = abi.decode(data, (uint256));
        _maybeExecuteProposal(module, id);
        return id;
    }

    function approveProposalByGateway(uint256 id, address adminSigner) external onlyAuthorizedGateway {
        address module = _module(MODULE_GOVERNANCE);
        (bool ok,) = module.delegatecall(abi.encodeWithSelector(IBeamioGovernanceModuleV1.approveProposalByGateway.selector, id, adminSigner));
        if (!ok) revert UC_NotAdmin();
        _maybeExecuteProposal(module, id);
    }

    function approveProposal(uint256 id) external onlyAdmin {
        address module = _module(MODULE_GOVERNANCE);
        (bool ok,) = module.delegatecall(abi.encodeWithSelector(IBeamioGovernanceModuleV1.approveProposal.selector, id));
        if (!ok) revert UC_InvalidProposal();
        _maybeExecuteProposal(module, id);
    }

    function _maybeExecuteProposal(address module, uint256 id) internal {
        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        GovernanceStorage.Proposal storage p = g.proposals[id];
        if (p.executed || p.approvals < g.threshold) return;
        (bool ok, bytes memory data) = module.delegatecall(abi.encodeWithSelector(IBeamioGovernanceModuleV1.executeProposal.selector, id));
        if (!ok) _revertDelegate(data);
        (bytes4 sel, address target, uint256 v1, uint256 v2, uint256 v3) = abi.decode(data, (bytes4, address, uint256, uint256, uint256));
        _executeWith(sel, target, v1, v2, v3);
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
        (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
        _mintMemberCardInternal(user, tierIndex);
        _recordAdminMembershipFlowForOperatorAndParents(owner(), issuedBefore, upgradedBefore);
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
        _callModule(
            MODULE_ISSUED_NFT,
            abi.encodeWithSelector(IBeamioIssuedNftModuleV1.validateAndRecordMintIssuedNft.selector, acct, tokenId, amount)
        );
        _mint(acct, tokenId, amount, "");
        emit IssuedNftMinted(tokenId, acct, amount);
    }

    /// @notice 检查 issued NFT 是否在有效期内
    function isIssuedNftValid(uint256 tokenId) external view returns (bool) {
        if (tokenId < ISSUED_NFT_START_ID) return false;
        IssuedNftStorage.Layout storage l = IssuedNftStorage.layout();
        uint64 va = l.issuedNftValidAfter[tokenId];
        uint64 vb = l.issuedNftValidBefore[tokenId];
        uint256 ts = block.timestamp;
        if (va != 0 && ts < va) return false;
        if (vb != 0 && ts > vb) return false;
        return true;
    }

    function _mintMemberCardInternal(address user, uint256 tierIndex) internal {
        _callModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.mintMemberCardInternal.selector, user, tierIndex)
        );
    }

    /// @dev 统计以 EOA 为键：每笔 transfer 仅记入一个 admin，避免 aggregate 时 double count
    /// @dev 有 beneficiaryAdmin 时记入接收方；否则记入 operator（发送方）
    /// @param originalTo ERC1155 调用中的原始 to（重定向前），用于判定 admin↔admin
    function _recordPointTransferStats(
        address from,
        address originalTo,
        address beneficiaryAdmin,
        address upperAdmin,
        uint256 count,
        uint256 amount
    ) internal {
        BeamioUserCardTransferLib.recordPointTransferStats(
            from, originalTo, beneficiaryAdmin, upperAdmin, count, amount, owner()
        );
    }

    /// @dev 每笔 redeem_mint 仅记入 operator，避免 aggregate 时 double count
    function _recordAdminRedeemMintForOperatorAndParents(address operator, uint256 amount) internal {
        if (operator == address(0) || amount == 0) return;
        AdminStatsStorage.recordRedeemMint(operator, amount);
    }

    /// @dev 每笔 usdc_mint 仅记入 operator，避免 aggregate 时 double count
    function _recordAdminUSDCMintForOperatorAndParents(address operator, uint256 amount) internal {
        if (operator == address(0) || amount == 0) return;
        AdminStatsStorage.recordUSDCMint(operator, amount);
    }

    // ==========================================================
    // ERC1155 update hook
    // ==========================================================
    function _updatePreProcess(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        view
        returns (UpdatePreResult memory r)
    {
        return BeamioUserCardTransferLib.updatePreProcess(factoryGateway(), from, to, ids, values);
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        UpdatePreResult memory r = _updatePreProcess(from, to, ids, values);

        super._update(from, r.effectiveTo, ids, values);

        bool isRealTransfer = (from != address(0) && to != address(0));
        if (isRealTransfer) {
            bool syncReceiverMembership;
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 mid = ids[i];
                if (mid < NFT_START_ID || mid >= ISSUED_NFT_START_ID) continue;
                if (values[i] == 0) continue;
                _removeNft(from, mid);
                _appendMembershipNftIfMissing(r.effectiveTo, mid);
                syncReceiverMembership = true;
            }
            if (syncReceiverMembership) _syncActiveToBestValid(r.effectiveTo);
        }
        if (isRealTransfer && (r.pointTransferCount > 0 || r.pointTransferAmount > 0)) {
            _recordPointTransferStats(
                from, to, r.beneficiaryAdmin, r.upperAdmin, r.pointTransferCount, r.pointTransferAmount
            );
        }

        if (upgradeType == 2 && isRealTransfer) {
            _callModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(
                    IBeamioMembershipStatsModuleV1.handlePointsTransferForUpgradeType2.selector,
                    from,
                    r.effectiveTo,
                    ids,
                    values
                )
            );
        }

        if (from == address(0)) {
            TotalSupplyStorage.Layout storage ts = TotalSupplyStorage.layout();
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 v = values[i];
                ts.totalSupplyById[ids[i]] += v;
                ts.totalSupplyAll += v;
            }
        }

        if (to == address(0)) {
            TotalSupplyStorage.Layout storage ts = TotalSupplyStorage.layout();
            uint256 totalBurnValue = 0;
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 v = values[i];
                unchecked {
                    ts.totalSupplyById[ids[i]] -= v;
                    totalBurnValue += v;
                }
            }
            unchecked { ts.totalSupplyAll -= totalBurnValue; }
        }

        for (uint256 i = 0; i < r.burnedCount; i++) {
            _removeNft(r.burnedFrom[i], r.burnedIds[i]);
        }

        if (from != address(0)) {
            bool pointsLeaveFrom;
            for (uint256 i = 0; i < ids.length; i++) {
                if (ids[i] == POINTS_ID && values[i] > 0) {
                    pointsLeaveFrom = true;
                    break;
                }
            }
            // upgradeType==2：升档由累计转给 admin 的 points 驱动；若此处再按扣款后余额对齐，会在同一 _update 内撤销刚执行的累计升档。
            // upgradeType==0：按单笔增量升档；不要求按余额维持档位，转出 points 时不得因余额下降而下调（与产品「升上去不降回」一致）。
            // upgradeType==1：按余额对齐档位，转出后允许依新余额下调（allowUpgrade=false 跳过升、仍可走对齐里的降档分支）。
            if (pointsLeaveFrom && upgradeType == 1) {
                _alignMembershipTierToPointsBalance(from, false);
            }
        }
    }

    function _removeNft(address user, uint256 id) internal {
        _callModule(MODULE_MEMBERSHIP_STATS, abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.removeNft.selector, user, id));
    }

    /// @dev 会员档 NFT 转移后写入接收方 `_userOwnedNfts`，否则 `_findBestValidMembership` 无法发现该 id
    function _appendMembershipNftIfMissing(address acct, uint256 id) internal {
        uint256[] storage list = _userOwnedNfts[acct];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == id) return;
        }
        list.push(id);
    }

    // ==========================================================
    // Views
    // ==========================================================
    function totalSupply(uint256 id) public view returns (uint256) {
        return TotalSupplyStorage.layout().totalSupplyById[id];
    }

    function totalSupply() public view returns (uint256) {
        return TotalSupplyStorage.layout().totalSupplyAll;
    }

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

    function membershipFlowBucketAtHour(uint64 hourIndex)
        external
        view
        returns (
            uint256 issuedCount,
            uint256 upgradedCount,
            uint256 expiredDiscoveredCount,
            uint256 activeSwitchCount,
            uint256 activatedCount,
            uint256 deactivatedCount,
            bool hasData
        )
    {
        MembershipStatsStorage.FlowBucket storage b = MembershipStatsStorage.layout().hourlyGlobal[hourIndex];
        return (
            b.issuedCount,
            b.upgradedCount,
            b.expiredDiscoveredCount,
            b.activeSwitchCount,
            b.activatedCount,
            b.deactivatedCount,
            b.hasData
        );
    }

    function membershipScopedFlowBucketAtHour(uint8 scopeType, uint256 scopeKey, uint64 hourIndex)
        external
        view
        returns (
            uint256 issuedCount,
            uint256 upgradedCount,
            uint256 expiredDiscoveredCount,
            uint256 activeSwitchCount,
            uint256 activatedCount,
            uint256 deactivatedCount,
            bool hasData
        )
    {
        MembershipStatsStorage.Layout storage s = MembershipStatsStorage.layout();
        MembershipStatsStorage.FlowBucket storage b =
            scopeType == 1 ? s.hourlyByTokenId[scopeKey][hourIndex] : s.hourlyByTierIndex[scopeKey][hourIndex];
        return (
            b.issuedCount,
            b.upgradedCount,
            b.expiredDiscoveredCount,
            b.activeSwitchCount,
            b.activatedCount,
            b.deactivatedCount,
            b.hasData
        );
    }

    // ==========================================================
    // Membership helpers
    // ==========================================================
    function _tierIndexWithMinThreshold() internal view returns (uint256) {
        if (tiers.length == 0) return type(uint256).max;
        uint256 idx = 0;
        uint256 minVal = tiers[0].minUsdc6;
        for (uint256 i = 1; i < tiers.length; i++) {
            if (tiers[i].minUsdc6 < minVal) {
                minVal = tiers[i].minUsdc6;
                idx = i;
            }
        }
        return idx;
    }

    function _maybeUpgradeByPointsBalance(address acct) internal {
        _callModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.maybeUpgradeByPointsBalance.selector, acct)
        );
    }

    function _alignMembershipTierToPointsBalance(address acct, bool allowUpgrade) internal {
        _callModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(
                IBeamioMembershipStatsModuleV1.alignMembershipTierToPointsBalance.selector,
                acct,
                allowUpgrade
            )
        );
    }

    function _maybeUpgrade(address acct, uint256 pointsDelta6) internal {
        _callModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.maybeUpgrade.selector, acct, pointsDelta6)
        );
    }

    function _isExpired(uint256 tokenId) internal view returns (bool) {
        uint256 exp = expiresAt[tokenId];
        return (exp != 0 && block.timestamp > exp);
    }

    function _hasValidCard(address acct) internal view returns (bool) {
        uint256 id = activeMembershipId[acct];
        return (id != 0 && balanceOf(acct, id) > 0 && !_isExpired(id));
    }

    /// @dev 无有效会员且配置了 tiers 时，points mint 须 ≥ 最低档门槛，否则整笔 revert（避免先 mint points 再拒发卡）
    function _requirePointsMintAllowsFirstMembership(address acct, uint256 points6) internal view {
        if (points6 == 0) return;
        if (_hasValidCard(acct)) return;
        if (tiers.length == 0) return;
        uint256 lowIdx = _tierIndexWithMinThreshold();
        if (points6 < tiers[lowIdx].minUsdc6) revert UC_BelowMinThreshold();
    }

    function _syncActiveToBestValid(address user) internal {
        _callModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.syncActiveToBestValid.selector, user)
        );
    }

    function _maybeIssueOnlyIfNoneOrExpiredByPointsDelta(address acctOrEOA, uint256 pointsDelta6) internal {
        _callModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(
                IBeamioMembershipStatsModuleV1.maybeIssueOnlyIfNoneOrExpiredByPointsDelta.selector,
                acctOrEOA,
                pointsDelta6
            )
        );
    }

    function _issueCardByPointsDelta_AssumingNoValidCard(address acct, uint256 pointsDelta6) internal {
        _callModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(
                IBeamioMembershipStatsModuleV1.issueCardByPointsDelta_AssumingNoValidCard.selector,
                acct,
                pointsDelta6
            )
        );
    }

    function _membershipFlowTotals() internal view returns (uint256 issued, uint256 upgraded) {
        return (totalMembershipIssued, totalMembershipUpgraded);
    }

    /// @dev 每笔 issued/upgraded 仅记入 operator，避免 aggregate 时 double count
    function _recordAdminMembershipFlowForOperatorAndParents(
        address operator,
        uint256 issuedBefore,
        uint256 upgradedBefore
    ) internal {
        uint256 issuedDelta = totalMembershipIssued - issuedBefore;
        uint256 upgradedDelta = totalMembershipUpgraded - upgradedBefore;
        if (operator == address(0) || (issuedDelta == 0 && upgradedDelta == 0)) return;
        AdminStatsStorage.recordMembershipFlow(operator, issuedDelta, upgradedDelta);
    }

    // ==========================================================
    // AA account resolve
    // ==========================================================
    function _toAccount(address maybeEoaOrAcct) internal view returns (address acct) {
        return BeamioUserCardTransferLib.toAccount(factoryGateway(), maybeEoaOrAcct);
    }

    function _resolveAccount(address eoa) internal view returns (address) {
        return BeamioUserCardTransferLib.resolveAccountForCard(factoryGateway(), eoa);
    }
}
