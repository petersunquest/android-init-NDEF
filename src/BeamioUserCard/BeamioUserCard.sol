// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioERC1155Logic.sol";
import "./BeamioCurrency.sol";
import "./Errors.sol";
import "./FaucetStorage.sol";
import "./IssuedNftStorage.sol";
import "./GovernanceStorage.sol";
import "./MembershipStatsStorage.sol";
import "./MembershipFeeStorage.sol";
import "./BeamioUserCardTierOpsLib.sol";
import "./TotalSupplyStorage.sol";
import "./AdminStatsStorage.sol";
import "./BeamioUserCardFormattingLib.sol";
import {BeamioUserCardTransferLib} from "./BeamioUserCardTransferLib.sol";
import "./BeamioUserCardViewsLib.sol";
import "./BeamioUserCardGatewayMintLib.sol";
import "./BeamioUserCardUpdateLib.sol";
import "./BeamioUserCardModuleRouterLib.sol";
import "./BeamioUserCardAdminGatewayLib.sol";
import "./BeamioUserCardRedeemGatewayLib.sol";
import "./BeamioUserCardInterfaces.sol";
import "./IBeamioUserCardSelfDelegate.sol";
import "./IBeamioUserCardNftInventory.sol";
import {
    NFTDetail,
    UpdatePreResult,
    UserCardTier,
    UserCardInitialTierConfig
} from "./BeamioUserCardTypes.sol";

import "../contracts/token/ERC1155/ERC1155.sol";
import "../contracts/access/Ownable.sol";
import "../contracts/utils/ReentrancyGuard.sol";

/* =========================================================
   BeamioUserCard
   ========================================================= */

contract BeamioUserCard is ERC1155, Ownable, ReentrancyGuard {
    using BeamioCurrency for *;

    // ===== Versioning =====
    /// @dev V20+: all initial tiers are configured atomically in Factory CREATE initCode.
    ///      V19+: burnPointsByAdmin (POS Charge settle) same-cycle #13 via UpdateLib (actor + referrer).
    ///      V18+: 3-arg appendTier for live Factory AndTiers (0x9a7eb0f0). upgradeByBalance = (upgradeType == 1).
    ///      V17+: Top-up mintPointsByAdmin may pack paid+total (bit255); #13 uses paid base only.
    ///      V16+: Charge same-cycle #13 via UpdateLib on real #0 transfer (actor + referrer).
    ///      Top-up #13 via GatewayMintLib → recordTopupCumulativeStat (ratio E6; not getRewardRule(2)).
    uint256 public constant VERSION = 21;

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
    uint8 private constant MODULE_CHARGE_REWARD = 5;
    uint8 private constant ROUTE_STATS_QUERY = type(uint8).max - 1;

    // ===== Deployer / gateway =====
    /// @dev Storage (not immutable) so BeaconProxy cards store the CREATE deployer correctly.
    address public deployer;
    address public gateway;
    address public debugGateway; // allow debug override

    /// @dev Ownable sentinel for the logic implementation (never used as a live card owner).
    address private constant _IMPL_OWNER_SENTINEL = 0x000000000000000000000000000000000000dEaD;

    /// @dev Lightweight init lock (avoids OZ Initializable bytecode bloat for EIP-170).
    ///      true after CREATE ctor, impl sentinel ctor, or successful `initialize` on a BeaconProxy.
    bool private _initializationLocked;

    error UC_AlreadyInitialized();
    error UC_InitializeLocked();

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
    /// @dev 0 = top-up tier; 1 = balance-align; 2 = points-transfer upgrade path (MembershipStats).
    uint8 public upgradeType;

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
    uint256 public totalMembershipIssued;
    uint256 public totalMembershipUpgraded;
    uint256 public totalActiveMemberships;
    mapping(uint256 => uint256) public totalMembershipIssuedByTierIndex;

    // NFTDetail imported from BeamioUserCardTypes (shared with ViewsLib)

    // ===== tiers =====
    UserCardTier[] public tiers;
    uint256 public defaultAttrWhenNoTiers;

    event TiersUpdated(uint256 count);
    event TierAppended(uint256 index, uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds, bool upgradeByBalance);
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

    /// @dev Charge / top-up actor reward mint (#13 after unified reward points).
    event ChargeRewardAirdropped(
        address indexed userEOA,
        address indexed acct,
        uint8 chargeCurrency,
        uint256 amountFiat6,
        uint256 rewardMinted
    );
    /// @dev Referrer #13 mint (legacy 3-arg shape kept for topic compatibility of first three fields).
    event ReferrerRewardMinted(address indexed refereeAA, address indexed referrerAA, uint256 rewardAmount);
    /// @dev Per-card referrer→referee earning ledger: kind 1=topup, 2=charge.
    event ReferrerRefereeRewardLedgered(
        address indexed referrer,
        address indexed referee,
        uint8 kind,
        uint256 amountFiat6,
        uint256 reward13E6
    );
    event IssuedNftPurchasedWithPointsCharge(
        address indexed userEOA,
        address indexed payeeEOA,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 totalPriceInCurrency6,
        uint256 pointsCharged6
    );

    // ===== current index (membership NFT; issued NFT index in IssuedNftStorage) =====
    uint256 private _currentIndex = NFT_START_ID;

    // ===== Redeem Events (emitted by card; module also emits its own) =====
    event RedeemCreated(bytes32 indexed hash, uint256 points6, uint256 attr);
    event RedeemCancelled(bytes32 indexed hash);

    // ==========================================================
    // ctor / initialize (CREATE + BeaconProxy)
    // ==========================================================
    /// @notice CREATE bootstrap (Factory Deployer) OR logic-impl sentinel.
    /// @dev Sentinel: `initialOwner == 0 && gateway_ == 0` → Ownable(dead) + lock init, no live card state.
    ///      CREATE: full bootstrap + lock so `initialize` cannot run on CREATE cards.
    ///      BeaconProxy: use `initialize` via proxy constructor `data` (impl stays locked).
    constructor(
        string memory uri_,
        BeamioCurrency.CurrencyType currency_,
        uint256 pointsUnitPriceInCurrencyE6_,
        address initialOwner,
        address gateway_
    )
        ERC1155("")
        Ownable(
            (initialOwner == address(0) && gateway_ == address(0)) ? _IMPL_OWNER_SENTINEL : initialOwner
        )
    {
        if (initialOwner == address(0) && gateway_ == address(0)) {
            _initializationLocked = true;
            return;
        }

        if (initialOwner == address(0)) revert BM_ZeroAddress();
        if (gateway_ == address(0) || gateway_.code.length == 0) revert UC_GlobalMisconfigured();

        _bootstrapCardState(uri_, currency_, pointsUnitPriceInCurrencyE6_, initialOwner, gateway_);
        _initializationLocked = true;
    }

    /// @notice BeaconProxy-only bootstrap. CREATE cards have init locked in the constructor.
    function initialize(
        string memory uri_,
        BeamioCurrency.CurrencyType currency_,
        uint256 pointsUnitPriceInCurrencyE6_,
        address initialOwner,
        address gateway_,
        bytes calldata initialTierConfig_
    ) external {
        if (_initializationLocked) revert UC_AlreadyInitialized();
        if (initialOwner == address(0)) revert BM_ZeroAddress();
        if (gateway_ == address(0) || gateway_.code.length == 0) revert UC_GlobalMisconfigured();

        _initializationLocked = true;
        _bootstrapCardState(uri_, currency_,pointsUnitPriceInCurrencyE6_, initialOwner, gateway_);
        _configureInitialTiers(abi.decode(initialTierConfig_, (UserCardInitialTierConfig)));
        _transferOwnership(initialOwner);
    }

    function _bootstrapCardState(
        string memory uri_,
        BeamioCurrency.CurrencyType currency_,
        uint256 pointsUnitPriceInCurrencyE6_,
        address initialOwner,
        address gateway_
    ) private {
        deployer = msg.sender;
        gateway = gateway_;
        debugGateway = gateway_;
        uri_; // kept for ABI compatibility; metadata base URI is shared in factory

        currency = currency_;
        pointsUnitPriceInCurrencyE6 = pointsUnitPriceInCurrencyE6_;

        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        g.threshold = 1;
        g.isAdmin[initialOwner] = true;
        g.adminList.push(initialOwner);

        IssuedNftStorage.Layout storage inft = IssuedNftStorage.layout();
        inft.issuedNftIndex = ISSUED_NFT_START_ID;
        // BeaconProxy does not copy constructor initializers; membership NFTs start at #100.
        _currentIndex = NFT_START_ID;
    }

    /// @dev New cards cannot be created with metadata-only tiers. Every acquisition
    /// mode writes its canonical schedule to `tiers` in the proxy initializer.
    function _configureInitialTiers(UserCardInitialTierConfig memory config) private {
        upgradeType = BeamioUserCardTierOpsLib.configureInitialTiers(tiers, config);
    }

    /// @notice Base Explorer / EIP-1155 约定：base URI 前缀 + 0x{合约地址}{id}.json，{id} 由客户端替换为 tokenId（64 位十六进制）
    function uri(uint256) public view override returns (string memory) {
        // External lib keeps main-card runtime under EIP-170 (24 KiB).
        return BeamioUserCardFormattingLib.buildErc1155MetadataUri(
            BeamioUserCardFormattingLib.resolveMetadataBaseURI(factoryGateway()), address(this)
        );
    }

    // ==========================================================
    // Tiers
    // ==========================================================
    function setDefaultAttr(uint256 attr) external {
        _requireOwnerOrGateway();
        emit DefaultAttrUpdated(defaultAttrWhenNoTiers);
        defaultAttrWhenNoTiers = attr;
    }

    /// @notice Live CoNET Factory AndTiers (3-tuple, selector 0x9a7eb0f0) calls this.
    ///         upgradeByBalance is derived from card-level upgradeType (1 = balance).
    function appendTier(uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds) external {
        _appendTier(minUsdc6, attr, tierExpirySeconds, upgradeType == 1);
    }

    /// @notice Factory appendTierForCard recover / 4-arg path. Prefer 3-arg AndTiers on create.
    function appendTier(uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds, bool upgradeByBalance) external {
        _appendTier(minUsdc6, attr, tierExpirySeconds, upgradeByBalance);
    }

    function _appendTier(uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds, bool upgradeByBalance) internal {
        _requireOwnerOrGateway();
        if (MembershipFeeStorage.isFeeMode()) revert UC_InvalidUpgradeType();
        BeamioUserCardTierOpsLib.appendTier(
            tiers, minUsdc6, attr, tierExpirySeconds, upgradeByBalance
        );
    }

    function setTiers(UserCardTier[] calldata newTiers) external {
        _requireOwnerOrGateway();
        BeamioUserCardTierOpsLib.replaceTiers(tiers, newTiers);
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
    // Delegatecall error bubbling
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
        bool hasValidCard = (activeMembershipId[acct] != 0);
        _mint(acct, outId, outAmount, "");
        uint256 pointsDelta6 = (outId == POINTS_ID) ? outAmount : 0;
        (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
        if (!hasValidCard) _issueCardByPointsDelta_AssumingNoValidCard(acct, pointsDelta6);
        else if (pointsDelta6 > 0) _maybeUpgrade(acct, pointsDelta6);
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
    // Redeem suite (owner issues; gateway consumes) — linked RedeemGatewayLib
    // ==========================================================

    /// @notice gateway 兑换 redeem-admin：用户提供秘密 code，匹配合格后添加 to 为 admin
    function redeemAdminByGateway(string calldata code, address to) external onlyAuthorizedGateway nonReentrant {
        BeamioUserCardRedeemGatewayLib.redeemAdminByGateway(IBeamioUserCardSelfDelegate(address(this)), code, to);
    }

    /// @notice gateway 兑换 redeem（统一处理 one-time 与 pool）
    function redeemByGateway(string calldata code, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        BeamioUserCardRedeemGatewayLib.redeemByGateway(IBeamioUserCardSelfDelegate(address(this)), code, userEOA);
    }

    /// @notice gateway consumes batch one-time redeem (multiple codes of same type) and mints to user's AA account
    function redeemBatchByGateway(string[] calldata codes, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        BeamioUserCardRedeemGatewayLib.redeemBatchByGateway(IBeamioUserCardSelfDelegate(address(this)), codes, userEOA);
    }

    /// @notice gateway 兑换 pool redeem，与 redeemByGateway 共用统一逻辑（自动识别 one-time/pool）
    function redeemPoolByGateway(string calldata code, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        BeamioUserCardRedeemGatewayLib.redeemByGateway(IBeamioUserCardSelfDelegate(address(this)), code, userEOA);
    }

    function _module(uint8 moduleKind) internal view returns (address module) {
        return BeamioUserCardModuleRouterLib.module(factoryGateway(), moduleKind);
    }

    function _callModule(uint8 moduleKind, bytes memory data) internal returns (bytes memory ret) {
        (bool ok, bytes memory out) = _module(moduleKind).delegatecall(data);
        ret = out;
        if (!ok) _revertDelegate(ret);
    }

    function _statsQueryModule() internal view returns (address module) {
        return BeamioUserCardModuleRouterLib.statsQueryModule(factoryGateway());
    }

    fallback() external {
        address module = BeamioUserCardModuleRouterLib.resolveFallbackModule(factoryGateway(), msg.sig);
        BeamioUserCardModuleRouterLib.delegateFallback(module);
    }

    function _requireOwnerOrGateway() internal view {
        address gw = debugGateway == address(0) ? gateway : debugGateway;
        if (msg.sender != owner() && msg.sender != gw) revert BM_NotAuthorized();
    }

    // ==========================================================
    // Gateway mint (no fund flow; used by FactoryPaymaster after USDC collected)
    // Linked BeamioUserCardGatewayMintLib: #0 + same-cycle proportional #13 (ratio E6)
    // ==========================================================
    /// @notice Gateway 代付 gas 为用户铸 points；资金流由 FactoryPaymaster 处理
    function mintPointsByGateway(address userEOA, uint256 points6) external onlyAuthorizedGateway nonReentrant {
        BeamioUserCardGatewayMintLib.mintPointsByGatewayWithOperator(
            IBeamioUserCardSelfDelegate(address(this)), userEOA, points6, owner()
        );
    }

    /// @notice Gateway 代付 gas 为用户铸 points；operator 可为 recommender admin 或 owner
    function mintPointsByGatewayWithOperator(address userEOA, uint256 points6, address operator)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        BeamioUserCardGatewayMintLib.mintPointsByGatewayWithOperator(
            IBeamioUserCardSelfDelegate(address(this)), userEOA, points6, operator
        );
    }

    // ==========================================================
    // Admin minting
    // ==========================================================
    function mintPointsByAdmin(address user, uint256 points6) external nonReentrant {
        _requireOwnerOrGateway();
        BeamioUserCardGatewayMintLib.mintPointsByAdmin(IBeamioUserCardSelfDelegate(address(this)), user, points6);
    }

    /// @notice Admin 离线签字后经 gateway 执行；operator 为签名 admin，自身及 parent 链记账
    /// @dev NFC / POS top-up: #0 + proportional #13 (recordTopupCumulativeStat / ratio E6) in one GatewayMintLib call.
    ///      getRewardRule(2) is legacy Social slot only — not used for Top-up Reward PT.
    function mintPointsByAdminWithOperator(address user, uint256 points6, address operator)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        if (!GovernanceStorage.layout().isAdmin[operator]) revert UC_NotAdmin();
        BeamioUserCardGatewayMintLib.mintPointsByAdminWithOperator(
            IBeamioUserCardSelfDelegate(address(this)), user, points6, operator
        );
    }

    /// @notice Admin 离线签字授权 burn 某一地址的 token 0；仅 gateway 调用，Factory executeForAdmin 验签后执行
    /// @param target 被 burn 的地址（EOA 或 AA）；signer 必须为 card admin
    /// @param amount 销毁数量；type(uint256).max 表示 burn 全部
    /// @dev POS Charge settles by burning customer `#0`. Burn is not a real transfer, so
    ///      processUpdatePost does not mint Charge Reward PT. V19+ calls UpdateLib after burn
    ///      so actor/referrer `#13` matches the transfer path (Master enqueue stays no-op).
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
        BeamioUserCardUpdateLib.afterAdminPointsBurn(
            IBeamioUserCardSelfDelegate(address(this)),
            acct,
            amount
        );
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
        BeamioUserCardAdminGatewayLib.clearAdminMintCounterForSubordinate(
            IBeamioUserCardSelfDelegate(address(this)), subordinate, authorizer
        );
    }

    /// @notice Owner 离线签字后经 gateway 的 executeForOwner 执行。仅清零 adminAddr 的 topup 相关计数（adminRedeemMintCounter、adminUSDCMintCounter），恢复 mintLimitPoints6 预定的 topup 额度。
    function resetAdminLimit(address adminAddr) external onlyAuthorizedGateway {
        BeamioUserCardAdminGatewayLib.resetAdminLimit(IBeamioUserCardSelfDelegate(address(this)), adminAddr);
    }

    /// @notice Admin 离线签字后经 gateway 的 executeForAdmin 执行。仅 adminParent[adminAddr] 可重置 subordinate，admin 自身无自重置权限。
    function resetAdminLimitByAdmin(address adminAddr, address authorizer) external onlyAuthorizedGateway {
        BeamioUserCardAdminGatewayLib.resetAdminLimitByAdmin(
            IBeamioUserCardSelfDelegate(address(this)), adminAddr, authorizer
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

    /// @dev TransferLib.updatePreProcess reads this via address(this); keep whitelist semantics here.
    function isPointsTransferRecipientAllowed(address effectiveTo) public view returns (bool) {
        if (!transferWhitelistEnabled) return true;
        if (transferWhitelist[address(0)]) return true;
        return transferWhitelist[effectiveTo];
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
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        UpdatePreResult memory r = BeamioUserCardTransferLib.updatePreProcess(factoryGateway(), from, to, ids, values);

        super._update(from, r.effectiveTo, ids, values);

        // Membership NFT sync + point transfer stats + Charge actor/referrer #13 (UpdateLib).
        BeamioUserCardUpdateLib.processUpdatePost(
            IBeamioUserCardSelfDelegate(address(this)), from, to, ids, values, r
        );
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

    /// @dev Inventory hooks for BeamioUserCardViewsLib (external DELEGATECALL target).
    function nftInventoryLength(address user) external view returns (uint256) {
        return _userOwnedNfts[user].length;
    }

    function nftInventoryAt(address user, uint256 index) external view returns (uint256) {
        return _userOwnedNfts[user][index];
    }

    function nftExpiresAt(uint256 tokenId) external view returns (uint256) {
        return expiresAt[tokenId];
    }

    function nftAttributes(uint256 tokenId) external view returns (uint256) {
        return attributes[tokenId];
    }

    function nftTierIndexOrMax(uint256 tokenId) external view returns (uint256) {
        return tokenTierIndexOrMax[tokenId];
    }

    function pointsBalanceOf(address user) external view returns (uint256) {
        return balanceOf(user, POINTS_ID);
    }

    function getOwnership(address user) public view returns (uint256 pt, NFTDetail[] memory nfts) {
        return BeamioUserCardViewsLib.getOwnership(IBeamioUserCardNftInventory(address(this)), user);
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
        return (id >= NFT_START_ID && id < ISSUED_NFT_START_ID && balanceOf(acct, id) > 0 && !_isExpired(id));
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

    // ==========================================================
    // IBeamioUserCardSelfDelegate (runtime library / module callbacks)
    // ==========================================================
    modifier onlySelf() {
        if (msg.sender != address(this)) revert BM_NotAuthorized();
        _;
    }

    function cardSelfMint(address to, uint256 id, uint256 amount) external onlySelf {
        _mint(to, id, amount, "");
    }

    function cardSelfBurn(address from, uint256 id, uint256 amount) external onlySelf {
        _burn(from, id, amount);
    }

    function cardSelfCallModule(uint8 kind, bytes calldata data) external onlySelf returns (bytes memory) {
        return _callModule(kind, data);
    }

    function cardSelfGovernanceDelegate(address module, bytes calldata data) external onlySelf returns (bool) {
        (bool ok,) = module.delegatecall(data);
        return ok;
    }

    function cardSelfAppendMembershipNftIfMissing(address acct, uint256 id) external onlySelf {
        uint256[] storage list = _userOwnedNfts[acct];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == id) return;
        }
        list.push(id);
    }

    function cardSelfMembershipFlowTotals() external view onlySelf returns (uint256 issued, uint256 upgraded) {
        return (totalMembershipIssued, totalMembershipUpgraded);
    }

    function cardSelfRecordAdminMembershipFlow(address operator, uint256 issuedBefore, uint256 upgradedBefore)
        external
        onlySelf
    {
        _recordAdminMembershipFlowForOperatorAndParents(operator, issuedBefore, upgradedBefore);
    }

    /// @dev No valid membership + tiers configured → points mint must meet lowest tier threshold.
    function cardSelfRequirePointsMintAllowsFirstMembership(address acct, uint256 points6) external view onlySelf {
        if (points6 == 0) return;
        if (_hasValidCard(acct)) return;
        uint256 len = tiers.length;
        if (len == 0) return;
        uint256 minVal = tiers[0].minUsdc6;
        for (uint256 i = 1; i < len; i++) {
            uint256 m = tiers[i].minUsdc6;
            if (m < minVal) minVal = m;
        }
        if (points6 < minVal) revert UC_BelowMinThreshold();
    }

    function cardSelfHasValidCard(address acct) external view onlySelf returns (bool) {
        return _hasValidCard(acct);
    }

    function cardSelfActiveMembershipId(address acct) external view onlySelf returns (uint256) {
        return activeMembershipId[acct];
    }

    /// @dev 0 when no tiers (skip min-threshold gate in RedeemGatewayLib).
    function cardSelfMinThresholdPoints6() external view onlySelf returns (uint256) {
        if (tiers.length == 0) return 0;
        return tiers[_tierIndexWithMinThreshold()].minUsdc6;
    }

    function cardSelfToAccount(address eoa) external view onlySelf returns (address) {
        return _toAccount(eoa);
    }

    function cardSelfUpgradeType() external view onlySelf returns (uint8) {
        return upgradeType;
    }

    function cardSelfPointsUnitPriceInCurrencyE6() external view onlySelf returns (uint256) {
        return pointsUnitPriceInCurrencyE6;
    }

    function cardSelfCurrencyType() external view onlySelf returns (uint8) {
        return uint8(currency);
    }

    function cardSelfEmitChargeRewardAirdropped(
        address userEOA,
        address acct,
        uint8 chargeCurrency,
        uint256 amountFiat6,
        uint256 reward
    ) external onlySelf {
        emit ChargeRewardAirdropped(userEOA, acct, chargeCurrency, amountFiat6, reward);
    }

    function cardSelfTransferPointsUpdate(address from, address to, uint256 amount) external onlySelf {
        uint256 bal = balanceOf(from, POINTS_ID);
        if (amount > bal) revert UC_InsufficientBalance(from, POINTS_ID, bal, amount);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory vals = new uint256[](1);
        ids[0] = POINTS_ID;
        vals[0] = amount;
        _update(from, to, ids, vals);
    }

    function cardSelfRecordAdminRedeemMint(address operator, uint256 amount) external onlySelf {
        _recordAdminRedeemMintForOperatorAndParents(operator, amount);
    }

    function cardSelfRecordAdminUsdcMint(address operator, uint256 amount) external onlySelf {
        _recordAdminUSDCMintForOperatorAndParents(operator, amount);
    }

    function cardSelfRecordAdminStatsMint(address operator, uint256 amount) external onlySelf {
        if (operator == address(0) || amount == 0) return;
        AdminStatsStorage.recordUSDCMint(operator, amount);
    }

    function cardSelfEmitFaucetClaimed(
        uint256 id,
        address userEOA,
        address acct,
        uint256 amount,
        uint256 claimedAfter
    ) external onlySelf {
        emit FaucetClaimed(id, userEOA, acct, amount, claimedAfter);
    }

    function cardSelfEmitPointsMintedByGateway(address userEOA, address acct, uint256 points6) external onlySelf {
        emit PointsMintedByGateway(userEOA, acct, points6);
    }

    function cardSelfEmitAdminPointsMinted(address acct, uint256 points6) external onlySelf {
        emit AdminPointsMinted(acct, points6);
    }

    function cardSelfEmitIssuedNftMinted(uint256 tokenId, address acct, uint256 amount) external onlySelf {
        emit IssuedNftMinted(tokenId, acct, amount);
    }

    function cardSelfEmitReferrerRewardMinted(
        address refereeAA,
        address referrerAA,
        uint256 rewardAmount,
        uint256 amountFiat6,
        uint8 kind
    ) external onlySelf {
        emit ReferrerRewardMinted(refereeAA, referrerAA, rewardAmount);
        emit ReferrerRefereeRewardLedgered(referrerAA, refereeAA, kind, amountFiat6, rewardAmount);
    }

    function cardSelfEmitIssuedNftPurchasedWithPointsCharge(
        address userEOA,
        address payeeEOA,
        uint256 tokenId,
        uint256 amount,
        uint256 totalPriceInCurrency6,
        uint256 pointsCharged6
    ) external onlySelf {
        emit IssuedNftPurchasedWithPointsCharge(
            userEOA, payeeEOA, tokenId, amount, totalPriceInCurrency6, pointsCharged6
        );
    }
}
