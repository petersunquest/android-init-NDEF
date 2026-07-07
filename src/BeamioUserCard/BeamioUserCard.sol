// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioERC1155Logic.sol";
import "./BeamioCurrency.sol";
import "./Errors.sol";
import "./RedeemStorage.sol";
import "./FaucetStorage.sol";
import "./IssuedNftStorage.sol";
import "./GovernanceStorage.sol";
import "./TotalSupplyStorage.sol";
import "./AdminStatsStorage.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardTypes.sol";
import "./BeamioUserCardFormattingLib.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./BeamioUserCardTransferLib.sol";
import "./ChargeRewardStorage.sol";
import "./ReferrerStorage.sol";
import "./IBeamioUserCardSelfDelegate.sol";
import "./BeamioUserCardReferrerLib.sol";
import "./BeamioUserCardUpdateLib.sol";
import "./BeamioUserCardFaucetGatewayLib.sol";
import "./BeamioUserCardRedeemGatewayLib.sol";
import "./BeamioUserCardGatewayMintLib.sol";
import "./BeamioUserCardIssuedNftGatewayLib.sol";
import "./BeamioUserCardGovernanceLib.sol";
import "./BeamioUserCardViewsLib.sol";
import "./BeamioUserCardModuleRouterLib.sol";
import "./BeamioUserCardAdminGatewayLib.sol";
import "./BeamioUserCardMembershipGateLib.sol";
import "./IBeamioUserCardMembershipGateView.sol";
import "./IBeamioUserCardNftInventory.sol";

import "../contracts/token/ERC1155/ERC1155.sol";
import "../contracts/access/Ownable.sol";
import "../contracts/utils/ReentrancyGuard.sol";

// 注意：IBeamioFactoryOracle, IBeamioAccountFactoryV07 已在 BeamioERC1155Logic.sol 中定义（资金流已移至 Factory）
// 其余模块 interface 见 BeamioUserCardInterfaces.sol

/* =========================================================
   BeamioUserCard
   ========================================================= */

contract BeamioUserCard is ERC1155, Ownable, ReentrancyGuard, IBeamioUserCardSelfDelegate, IBeamioUserCardNftInventory {
    using BeamioCurrency for *;

    // ===== Versioning =====
    uint256 public constant VERSION = 28;

    // ===== Constants (no magic numbers) =====
    uint256 public constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint8 public constant POINTS_DECIMALS = BeamioERC1155Logic.POINTS_DECIMALS;
    uint256 private constant POINTS_ONE = 10 ** uint256(POINTS_DECIMALS);
    uint256 public constant REFERRER_REWARD_TOKEN_ID = 1;
    uint256 public constant CHARGE_REWARD_TOKEN_ID = 2;
    uint256 private constant DEFAULT_CHARGE_REWARD_RATIO_E6 = 1_000_000;
    uint256 private constant DEFAULT_REFERRER_REWARD_FROM_CHARGE_REWARD_RATIO_E6 = 1_000_000;
    uint256 private constant REWARD_RATIO_ONE_E6 = 1_000_000;

    uint256 public constant NFT_START_ID = BeamioERC1155Logic.NFT_START_ID;
    uint256 public constant ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;
    uint8 private constant MODULE_REDEEM = BeamioUserCardModuleKinds.REDEEM;
    uint8 private constant MODULE_FAUCET = BeamioUserCardModuleKinds.FAUCET;
    uint8 private constant MODULE_ISSUED_NFT = BeamioUserCardModuleKinds.ISSUED_NFT;
    uint8 private constant MODULE_GOVERNANCE = BeamioUserCardModuleKinds.GOVERNANCE;
    uint8 private constant MODULE_MEMBERSHIP_STATS = BeamioUserCardModuleKinds.MEMBERSHIP_STATS;
    uint8 private constant MODULE_CHARGE_REWARD = BeamioUserCardModuleKinds.CHARGE_REWARD;

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
    event ChargeRewardAirdropped(
        address indexed userEOA,
        address indexed acct,
        uint8 chargeCurrency,
        uint256 amountFiat6,
        uint256 rewardMinted
    );
    event RefereeRegistered(address indexed refereeAA, address indexed operator);
    event RefereeUnregistered(address indexed refereeAA, address indexed operator);
    event RefereeReferrerUpdated(address indexed refereeAA, address indexed referrerAA, address indexed operator);
    event ReferrerRewardRatioUpdated(uint256 oldRatioE6, uint256 newRatioE6);
    event ReferrerRewardMinted(
        address indexed refereeAA,
        address indexed referrerAA,
        uint256 rewardAmount
    );

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
    event IssuedNftPurchasedWithPointsCharge(
        address indexed userEOA,
        address indexed payeeEOA,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 totalPriceInCurrency6,
        uint256 pointsCharged6
    );

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

    /// @dev Explorer-facing contract name. Kept after existing storage to avoid shifting module slots.
    string private _contractName;

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
        bool initialTransferWhitelistEnabled,
        string memory contractName_
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
        _contractName = contractName_;
        ChargeRewardStorage.layout().chargeRewardRatioE6 = DEFAULT_CHARGE_REWARD_RATIO_E6;
        ReferrerStorage.layout().referrerRewardFromChargeRewardRatioE6 =
            DEFAULT_REFERRER_REWARD_FROM_CHARGE_REWARD_RATIO_E6;
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

    /// @notice Contract-level token name for explorers that index ERC-1155 contracts via name().
    function name() external view returns (string memory) {
        bytes memory n = bytes(_contractName);
        return n.length == 0 ? "Beamio User Card" : string(n);
    }

    /// @notice Contract-level token symbol for explorers that index ERC-1155 contracts via symbol().
    function symbol() external pure returns (string memory) {
        return "BEAMIO";
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

    function issuedNftSharedMetadataHash(uint256 tokenId) external view returns (bytes32) {
        return IssuedNftStorage.layout().issuedNftSharedMetadataHash[tokenId];
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
        BeamioUserCardFaucetGatewayLib.faucetByGateway(IBeamioUserCardSelfDelegate(address(this)), userEOA, id, amount);
    }

    /// @notice Gateway mint for paid faucet；资金流由 FactoryPaymaster.purchaseFaucetForUser 处理
    function mintFaucetByGateway(address userEOA, uint256 id, uint256 amount6) external onlyAuthorizedGateway nonReentrant {
        BeamioUserCardFaucetGatewayLib.mintFaucetByGateway(
            IBeamioUserCardSelfDelegate(address(this)), userEOA, id, amount6
        );
    }

    // ==========================================================
    // Redeem suite (owner issues; gateway consumes)
    // ==========================================================

    function redeemAdminByGateway(string calldata code, address to) external onlyAuthorizedGateway nonReentrant {
        BeamioUserCardRedeemGatewayLib.redeemAdminByGateway(
            IBeamioUserCardSelfDelegate(address(this)), code, to, _module(MODULE_GOVERNANCE)
        );
    }

    /// @notice gateway 兑换 redeem（统一处理 one-time 与 pool）
    function redeemByGateway(string calldata code, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        BeamioUserCardRedeemGatewayLib.redeemByGateway(IBeamioUserCardSelfDelegate(address(this)), code, userEOA);
    }

    function redeemBatchByGateway(string[] calldata codes, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        BeamioUserCardRedeemGatewayLib.redeemBatchByGateway(
            IBeamioUserCardSelfDelegate(address(this)), codes, userEOA
        );
    }

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

    fallback() external {
        BeamioUserCardModuleRouterLib.delegateFallback(
            BeamioUserCardModuleRouterLib.resolveFallbackModule(factoryGateway(), msg.sig)
        );
    }

    function _requireOwnerOrGateway() internal view {
        address gw = debugGateway == address(0) ? gateway : debugGateway;
        if (msg.sender != owner() && msg.sender != gw) revert BM_NotAuthorized();
    }

    function _requireOwnerOrAdmin() internal view {
        if (msg.sender != owner() && !GovernanceStorage.layout().isAdmin[msg.sender]) revert BM_NotAuthorized();
    }

    function _requireRegisteredBeamioAccount(address acct) internal view {
        if (acct == address(0)) revert BM_ZeroAddress();
        address aaFactory = IBeamioFactoryOracle(factoryGateway()).aaFactory();
        if (!IBeamioAccountFactoryV07(aaFactory).isBeamioAccount(acct)) revert UC_NoBeamioAccount();
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

    /// @notice parent admin 清零 subordinate 的 mint/burn/transfer 计数（仅 gateway 调用，Factory executeForAdmin 支持）
    /// @param subordinate 被清零的 admin
    /// @param authorizer 必须等于 adminParent[subordinate]，即 parent；Factory 验签后传入 signer
    function clearAdminMintCounterForSubordinate(address subordinate, address authorizer) external onlyAuthorizedGateway {
        BeamioUserCardAdminGatewayLib.clearAdminMintCounterForSubordinate(
            IBeamioUserCardSelfDelegate(address(this)), subordinate, authorizer
        );
    }

    function resetAdminLimit(address adminAddr) external onlyAuthorizedGateway {
        BeamioUserCardAdminGatewayLib.resetAdminLimit(IBeamioUserCardSelfDelegate(address(this)), adminAddr);
    }

    function resetAdminLimitByAdmin(address adminAddr, address authorizer) external onlyAuthorizedGateway {
        BeamioUserCardAdminGatewayLib.resetAdminLimitByAdmin(
            IBeamioUserCardSelfDelegate(address(this)), adminAddr, authorizer
        );
    }

    function createProposal(bytes4 selector, address target, uint256 v1, uint256 v2, uint256 v3)
        external
        onlyAuthorizedGateway
        returns (uint256)
    {
        return BeamioUserCardGovernanceLib.createProposal(
            IBeamioUserCardSelfDelegate(address(this)), _module(MODULE_GOVERNANCE), selector, target, v1, v2, v3
        );
    }

    function approveProposalByGateway(uint256 id, address adminSigner) external onlyAuthorizedGateway {
        BeamioUserCardGovernanceLib.approveProposalByGateway(
            IBeamioUserCardSelfDelegate(address(this)), _module(MODULE_GOVERNANCE), id, adminSigner
        );
    }

    function approveProposal(uint256 id) external onlyAdmin {
        BeamioUserCardGovernanceLib.approveProposal(
            IBeamioUserCardSelfDelegate(address(this)), _module(MODULE_GOVERNANCE), id
        );
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
        _callModule(
            MODULE_MEMBERSHIP_STATS,
            abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.mintMemberCardInternal.selector, user, tierIndex)
        );
        _recordAdminMembershipFlowForOperatorAndParents(owner(), issuedBefore, upgradedBefore);
    }

    /// @notice Owner 直接 mint 给受益人（免费，用于分发/兑换等）
    function mintIssuedNftByOwner(address to, uint256 tokenId, uint256 amount) external nonReentrant {
        _requireOwnerOrGateway();
        if (to == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();
        BeamioUserCardIssuedNftGatewayLib.mintIssuedNftChecked(
            IBeamioUserCardSelfDelegate(address(this)), _toAccount(to), tokenId, amount
        );
    }

    function mintIssuedNftByUserSigClaim(address userEOA, uint256 tokenId) external onlyAuthorizedGateway nonReentrant {
        BeamioUserCardIssuedNftGatewayLib.mintIssuedNftByUserSigClaim(
            IBeamioUserCardSelfDelegate(address(this)), userEOA, tokenId
        );
    }

    function recordSocialExchangeUsdcClaim(address userEOA, uint256 tokenId) external onlyAuthorizedGateway nonReentrant {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        _callModule(
            MODULE_ISSUED_NFT,
            abi.encodeWithSelector(
                IBeamioIssuedNftModuleV1.validateAndRecordSocialExchangeUsdcClaim.selector, userEOA, tokenId
            )
        );
    }

    function burnSocialPointsForExchange(address userEOA, uint256 pointsCost) external onlyAuthorizedGateway nonReentrant {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        _callModule(
            MODULE_CHARGE_REWARD,
            abi.encodeWithSelector(
                IBeamioChargeRewardModuleV2SocialExchange.burnSocialPointsFromUserForExchange.selector,
                userEOA,
                pointsCost
            )
        );
    }

    function payoutSocialExchangeUsdc(address userEOA, uint256 usdcReward6) external onlyAuthorizedGateway nonReentrant {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        _callModule(
            MODULE_CHARGE_REWARD,
            abi.encodeWithSelector(
                IBeamioChargeRewardModuleV2SocialExchange.payoutSocialExchangeUsdcToUser.selector, userEOA, usdcReward6
            )
        );
    }

    function fundSocialExchangeUsdcEscrow(address payerEOA, uint256 amount6) external onlyAuthorizedGateway nonReentrant {
        if (payerEOA == address(0)) revert BM_ZeroAddress();
        _callModule(
            MODULE_CHARGE_REWARD,
            abi.encodeWithSelector(
                IBeamioChargeRewardModuleV2SocialExchange.fundSocialExchangeUsdcEscrow.selector, payerEOA, amount6
            )
        );
    }

    function mintIssuedNftByGateway(address userEOA, uint256 tokenId, uint256 amount) external onlyAuthorizedGateway nonReentrant {
        BeamioUserCardIssuedNftGatewayLib.mintIssuedNftByGateway(
            IBeamioUserCardSelfDelegate(address(this)), userEOA, tokenId, amount
        );
    }

    function purchaseIssuedNftWithPointsCharge(
        address userEOA,
        uint256 tokenId,
        uint256 amount,
        address payeeEOA
    ) external onlyAuthorizedGateway nonReentrant {
        BeamioUserCardIssuedNftGatewayLib.purchaseIssuedNftWithPointsCharge(
            IBeamioUserCardSelfDelegate(address(this)), userEOA, tokenId, amount, payeeEOA, pointsUnitPriceInCurrencyE6
        );
    }

    function quoteIssuedNftPurchasePoints6(uint256 tokenId, uint256 amount)
        external
        view
        returns (uint256 points6, uint256 totalPriceInCurrency6)
    {
        return BeamioUserCardIssuedNftGatewayLib.quoteIssuedNftPurchasePoints6(
            tokenId, amount, pointsUnitPriceInCurrencyE6
        );
    }

    // ==========================================================
    // Referrer registry (referee AA + uplink referrer AA)
    // ==========================================================

    /// @notice Owner/admin registers a Beamio AA as an eligible referee on this card.
    function registerReferee(address refereeAA) external {
        _requireOwnerOrAdmin();
        _requireRegisteredBeamioAccount(refereeAA);
        BeamioUserCardReferrerLib.registerReferee(refereeAA);
        emit RefereeRegistered(refereeAA, msg.sender);
    }

    /// @notice Owner/admin removes a referee registration and clears its uplink referrer.
    function unregisterReferee(address refereeAA) external {
        _requireOwnerOrAdmin();
        BeamioUserCardReferrerLib.unregisterReferee(refereeAA);
        emit RefereeUnregistered(refereeAA, msg.sender);
    }

    /// @notice Owner/admin sets the uplink referrer for a registered referee (single level).
    function setRefereeReferrer(address refereeAA, address referrerAA) external {
        _requireOwnerOrAdmin();
        _requireRegisteredBeamioAccount(refereeAA);
        _requireRegisteredBeamioAccount(referrerAA);
        BeamioUserCardReferrerLib.setRefereeReferrer(refereeAA, referrerAA);
        emit RefereeReferrerUpdated(refereeAA, referrerAA, msg.sender);
    }

    /// @notice Owner/admin clears uplink referrer for a registered referee.
    function clearRefereeReferrer(address refereeAA) external {
        _requireOwnerOrAdmin();
        BeamioUserCardReferrerLib.clearRefereeReferrer(refereeAA);
        emit RefereeReferrerUpdated(refereeAA, address(0), msg.sender);
    }

    function isRegisteredReferee(address refereeAA) external view returns (bool) {
        return ReferrerStorage.layout().isReferee[refereeAA];
    }

    function refereeReferrer(address refereeAA) external view returns (address) {
        return ReferrerStorage.layout().referrerOfReferee[refereeAA];
    }

    /// @notice Total distinct referrer AAs on this card (each has ≥1 downline referee).
    function referrerTotalCount() external view returns (uint256) {
        return BeamioUserCardReferrerLib.referrerTotalCount();
    }

    /// @notice Downline referee count for a referrer AA.
    function refereeCountByReferrer(address referrerAA) external view returns (uint256) {
        return BeamioUserCardReferrerLib.refereeCountByReferrer(referrerAA);
    }

    /// @notice Total registered referee AAs on this card.
    function registeredRefereeTotalCount() external view returns (uint256) {
        return BeamioUserCardReferrerLib.registeredRefereeTotalCount();
    }

    /// @notice Lifetime cumulative token #0 charge volume for a referee AA (6 decimals).
    function refereeChargePointsTotal6(address refereeAA) external view returns (uint256) {
        return ReferrerStorage.layout().refereeChargePointsTotal6[refereeAA];
    }

    /// @notice E6 ratio: token #1 minted per token #2 charge-reward; 1_000_000 = 1:1; 0 = disabled.
    function referrerRewardFromChargeRewardRatioE6() external view returns (uint256) {
        return ReferrerStorage.layout().referrerRewardFromChargeRewardRatioE6;
    }

    function previewReferrerRewardFromChargeReward(uint256 chargeRewardAmount) external view returns (uint256) {
        return BeamioUserCardReferrerLib.calcReferrerRewardFromChargeReward(chargeRewardAmount);
    }

    /// @notice Owner/admin sets how much token #1 referrer receives per token #2 charge-reward minted to referee.
    function setReferrerRewardRatio(uint256 ratioE6) external {
        _requireOwnerOrAdmin();
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        uint256 old = r.referrerRewardFromChargeRewardRatioE6;
        r.referrerRewardFromChargeRewardRatioE6 = ratioE6;
        emit ReferrerRewardRatioUpdated(old, ratioE6);
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
        BeamioUserCardUpdateLib.processUpdatePost(
            IBeamioUserCardSelfDelegate(address(this)), from, to, ids, values, r
        );
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
        return BeamioUserCardViewsLib.getOwnership(IBeamioUserCardNftInventory(address(this)), user);
    }

    function getOwnershipByEOA(address userEOA) external view returns (uint256 pt, NFTDetail[] memory nfts) {
        return getOwnership(_resolveAccount(userEOA));
    }

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

    // ==========================================================
    // Membership helpers (IBeamioUserCardMembershipGateView + BeamioUserCardMembershipGateLib)
    // ==========================================================
    function tiersLength() external view returns (uint256) {
        return tiers.length;
    }

    function _membershipGateView() private view returns (IBeamioUserCardMembershipGateView) {
        return IBeamioUserCardMembershipGateView(address(this));
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

    // ==========================================================
    // IBeamioUserCardSelfDelegate (runtime library callbacks)
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

    function cardSelfRequirePointsMintAllowsFirstMembership(address acct, uint256 points6) external view onlySelf {
        BeamioUserCardMembershipGateLib.requirePointsMintAllowsFirstMembership(_membershipGateView(), acct, points6);
    }

    function cardSelfHasValidCard(address acct) external view onlySelf returns (bool) {
        return BeamioUserCardMembershipGateLib.hasValidCard(_membershipGateView(), acct);
    }

    function cardSelfToAccount(address eoa) external view onlySelf returns (address) {
        return _toAccount(eoa);
    }

    function cardSelfOwner() external view onlySelf returns (address) {
        return owner();
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

    function cardSelfEmitReferrerRewardMinted(address refereeAA, address referrerAA, uint256 rewardAmount)
        external
        onlySelf
    {
        emit ReferrerRewardMinted(refereeAA, referrerAA, rewardAmount);
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
