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
    function defaultFaucetModule() external view returns (address);
    function defaultIssuedNftModule() external view returns (address);
    function defaultGovernanceModule() external view returns (address);
    function defaultMembershipStatsModule() external view returns (address);
    function defaultAdminStatsQueryModule() external view returns (address);
    function metadataBaseURI() external view returns (string memory);
}

interface IBeamioUserCardSelectorRouter {
    function selectorModuleKind(bytes4 sel) external pure returns (uint8);
}

/**
 * @dev RedeemModule VNext ABI (delegatecall target)
 */
interface IBeamioRedeemModuleVNext {
    function createRedeemAdmin(bytes32 hash, string calldata metadata, uint64 validAfter, uint64 validBefore) external;
    function createRedeemAdmin(bytes32 hash, string calldata metadata, uint64 validAfter, uint64 validBefore, uint256 mintLimit) external;
    function consumeRedeemAdmin(string calldata code) external returns (string memory metadata, uint256 mintLimit);
    function cancelRedeemAdmin(bytes32 hash) external;

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

    function createRedeemWithCreator(bytes32 hash, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256[] calldata tokenIds, uint256[] calldata amounts, address creator) external;
    function createRedeemWithCreatorAndRecommender(bytes32 hash, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256[] calldata tokenIds, uint256[] calldata amounts, address creator, address recommender) external;
    function createRedeemBatchWithCreator(bytes32[] calldata hashes, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256[] calldata tokenIds, uint256[] calldata amounts, address creator) external;
    function createRedeemBatchWithCreatorAndRecommender(bytes32[] calldata hashes, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256[] calldata tokenIds, uint256[] calldata amounts, address creator, address recommender) external;
    function createRedeemPoolWithCreator(bytes32 poolHash, uint64 validAfter, uint64 validBefore, uint256[][] calldata tokenIdsList, uint256[][] calldata amountsList, uint32[] calldata counts, address creator) external;
    function createRedeemPoolWithCreatorAndRecommender(bytes32 poolHash, uint64 validAfter, uint64 validBefore, uint256[][] calldata tokenIdsList, uint256[][] calldata amountsList, uint32[] calldata counts, address creator, address recommender) external;
    function getRedeemCreator(string calldata code) external view returns (address creator);
    function getRedeemRecommender(string calldata code) external view returns (address recommender);
    function getRedeemAdminStatus(bytes32 hash) external view returns (bool active);
    function getRedeemAdminList() external view returns (bytes32[] memory);
}

interface IBeamioFaucetModuleV1 {
    function setFaucetConfig(uint256 id, uint64 validUntil, uint64 perClaimMax, uint128 maxPerUser, uint128 maxGlobal, bool enabled, uint8 currency, uint128 priceInCurrency6) external;
    function validateAndRecordFreeFaucet(address userEOA, uint256 id, uint256 amount) external returns (uint256 outId, uint256 outAmount);
    function validateAndRecordPaidFaucet(address userEOA, uint256 id, uint256 amount6) external returns (uint256 outId, uint256 outAmount);
}

interface IBeamioIssuedNftModuleV1 {
    function createIssuedNft(bytes32 title, uint64 validAfter, uint64 validBefore, uint256 maxSupply, uint256 priceInCurrency6, bytes32 sharedMetadataHash) external returns (uint256 tokenId);
    function validateAndRecordMintIssuedNft(address acct, uint256 tokenId, uint256 amount) external;
}

interface IBeamioGovernanceModuleV1 {
    function adminManager(address to, bool admin, uint256 newThreshold, string calldata metadata) external;
    function adminManager(address to, bool admin, uint256 newThreshold, string calldata metadata, uint256 mintLimit) external;
    function adminManagerByAdmin(address to, bool admin, uint256 newThreshold, string calldata metadata, address authorizer) external;
    function adminManagerByAdmin(address to, bool admin, uint256 newThreshold, string calldata metadata, address authorizer, uint256 mintLimit) external;
    function setAdminAirdropLimit(address adminAddr, uint256 mintLimit) external;
    function setAdminAirdropLimitByAdmin(address adminAddr, uint256 mintLimit, address authorizer) external;
    function enforceAndRecordAdminAirdropLimit(address admin, uint256 points6) external;
    function clearAdminStatsAndAirdropUsageForSubordinate(address subordinate, address authorizer) external;
    function resetAdminLimit(address adminAddr) external;
    function resetAdminLimitByAdmin(address adminAddr, address authorizer) external;
    function createProposal(bytes4 selector, address target, uint256 v1, uint256 v2, uint256 v3) external returns (uint256 id);
    function approveProposalByGateway(uint256 id, address adminSigner) external;
    function approveProposal(uint256 id) external;
    function executeProposal(uint256 id) external returns (bytes4 selector, address target, uint256 v1, uint256 v2, uint256 v3);
}

interface IBeamioMembershipStatsModuleV1 {
    function mintMemberCardInternal(address user, uint256 tierIndex) external;
    function removeNft(address user, uint256 id) external;
    function maybeUpgradeByPointsBalance(address acct) external;
    function maybeUpgrade(address acct, uint256 pointsDelta6) external;
    function syncActiveToBestValid(address user) external;
    function maybeIssueOnlyIfNoneOrExpiredByPointsDelta(address acctOrEOA, uint256 pointsDelta6) external;
    function issueCardByPointsDelta_AssumingNoValidCard(address acct, uint256 pointsDelta6) external;
}



/* =========================================================
   BeamioUserCard
   ========================================================= */

contract BeamioUserCard is ERC1155, Ownable, ReentrancyGuard {
    using BeamioCurrency for *;

    // ===== Versioning =====
    uint256 public constant VERSION = 12;

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

    // ===== tiers =====
    struct Tier {
        uint256 minUsdc6; // Tier thresholds are points-based (semantic: minPointsDelta6), not direct USDC balances.
        uint256 attr;
        uint256 tierExpirySeconds; // 0 => use global expirySeconds
        /// @dev true = 按余额达到 minUsdc6 即升级到本档；false = 按单次 topup/redeem 金额达到 minUsdc6 即升级到本档
        bool upgradeByBalance;
    }
    Tier[] public tiers;
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

    // ===== current index (membership NFT; issued NFT index in IssuedNftStorage) =====
    uint256 private _currentIndex = NFT_START_ID;

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
    ) ERC1155("") Ownable(initialOwner) {
        if (initialOwner == address(0)) revert BM_ZeroAddress();
        if (gateway_ == address(0) || gateway_.code.length == 0) revert UC_GlobalMisconfigured();

        deployer = msg.sender;
        gateway = gateway_;
        debugGateway = gateway_;
        uri_; // kept for constructor ABI compatibility; metadata base URI is shared in factory

        currency = currency_;
        pointsUnitPriceInCurrencyE6 = pointsUnitPriceInCurrencyE6_;

        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        g.threshold = 1;
        g.isAdmin[initialOwner] = true;
        g.adminList.push(initialOwner);

        IssuedNftStorage.Layout storage inft = IssuedNftStorage.layout();
        inft.issuedNftIndex = ISSUED_NFT_START_ID;
    }

    /// @notice Base Explorer / EIP-1155 约定：base URI 前缀 + 0x{合约地址}{id}.json，{id} 由客户端替换为 tokenId（64 位十六进制）
    function uri(uint256) public view override returns (string memory) {
        return string(abi.encodePacked(_metadataBaseURI(), _addressToHex40(address(this)), "{id}.json"));
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

    function _addressToHex40(address a) internal pure returns (string memory) {
        bytes memory b = abi.encodePacked(a);
        bytes memory h = "0123456789abcdef";
        bytes memory r = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            r[i * 2] = h[uint8(b[i]) >> 4];
            r[i * 2 + 1] = h[uint8(b[i]) & 0x0f];
        }
        return string(r);
    }

    // ==========================================================
    // Tiers
    // ==========================================================
    function setDefaultAttr(uint256 attr) external {
        _requireOwnerOrGateway();
        emit DefaultAttrUpdated(defaultAttrWhenNoTiers);
        defaultAttrWhenNoTiers = attr;
    }

    function appendTier(uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds, bool upgradeByBalance) external {
        _requireOwnerOrGateway();
        if (minUsdc6 == 0) revert UC_TierMinZero();
        uint256 idx = tiers.length;
        tiers.push(Tier(minUsdc6, attr, tierExpirySeconds, upgradeByBalance));
        emit TierAppended(idx, minUsdc6, attr, tierExpirySeconds, upgradeByBalance);
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

    function _getRedeemCreator(string calldata code) internal view returns (address creator) {
        if (bytes(code).length == 0) return address(0);
        bytes32 hash = keccak256(bytes(code));
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return r.creator;
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active) return p.creator;
        return address(0);
    }

    function _getRedeemRecommender(string calldata code) internal view returns (address recommender) {
        if (bytes(code).length == 0) return address(0);
        bytes32 hash = keccak256(bytes(code));
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return r.recommender;
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active) return p.recommender;
        return address(0);
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
        address creator = _getRedeemCreator(code); // 兑换前读取 creator，用于 admin 记账
        address recommender = _getRedeemRecommender(code); // 兑换前读取 recommender，用于单独 redeem_mint 记账
        bytes memory data = _callModule(
            MODULE_REDEEM,
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeem.selector, code, userEOA)
        );
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
            uint256 minReqPoints6 = tiers[_tierIndexWithMinThreshold()].minUsdc6;
            if (totalPoints6 < minReqPoints6) revert UC_BelowMinThreshold();
        }

        if (totalPoints6 > 0) {
            _mint(acct, POINTS_ID, totalPoints6, "");
            AdminStatsStorage.recordMint(creator != address(0) ? creator : owner(), totalPoints6);
            _recordAdminRedeemMintForOperatorAndParents(recommender, totalPoints6);
        }

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

        address statsOperator = creator != address(0) ? creator : owner();
        (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
        if (!hasValidCard) _issueCardByPointsDelta_AssumingNoValidCard(acct, totalPoints6);
        else _maybeUpgrade(acct, totalPoints6);
        _recordAdminMembershipFlowForOperatorAndParents(statsOperator, issuedBefore, upgradedBefore);
    }

    /// @notice gateway consumes batch one-time redeem (multiple codes of same type) and mints to user's AA account
    function redeemBatchByGateway(string[] calldata codes, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (codes.length == 0) revert UC_InvalidProposal();
        address creator = codes.length > 0 ? _getRedeemCreator(codes[0]) : address(0); // batch 同类型，creator 相同
        address recommender = codes.length > 0 ? _getRedeemRecommender(codes[0]) : address(0); // batch 同类型，recommender 相同
        bytes memory data = _callModule(
            MODULE_REDEEM,
            abi.encodeWithSelector(IBeamioRedeemModuleVNext.consumeRedeemBatch.selector, codes, userEOA)
        );
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
            uint256 minReqPoints6 = tiers[_tierIndexWithMinThreshold()].minUsdc6;
            if (totalPoints6 < minReqPoints6) revert UC_BelowMinThreshold();
        }

        if (totalPoints6 > 0) {
            _mint(acct, POINTS_ID, totalPoints6, "");
            AdminStatsStorage.recordMint(creator != address(0) ? creator : owner(), totalPoints6);
            _recordAdminRedeemMintForOperatorAndParents(recommender, totalPoints6);
        }

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

        address statsOperator = creator != address(0) ? creator : owner();
        (uint256 issuedBefore, uint256 upgradedBefore) = _membershipFlowTotals();
        if (!hasValidCard) _issueCardByPointsDelta_AssumingNoValidCard(acct, totalPoints6);
        else _maybeUpgrade(acct, totalPoints6);
        _recordAdminMembershipFlowForOperatorAndParents(statsOperator, issuedBefore, upgradedBefore);
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

    function _mintPointsByGatewayWithOperator(address userEOA, uint256 points6, address operator) internal {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (operator == address(0)) revert BM_ZeroAddress();
        if (points6 == 0) revert UC_AmountZero();

        address acct = _toAccount(userEOA);
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

    function _resolveTransferStatsOperator(address from) internal view returns (address operator) {
        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        if (g.isAdmin[msg.sender]) return msg.sender;
        if (from == address(0) || from.code.length == 0) return address(0);

        (bool ok, bytes memory ret) = from.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return address(0);
        address ownerOfFrom = abi.decode(ret, (address));
        if (g.isAdmin[ownerOfFrom]) return ownerOfFrom;
        return address(0);
    }

    /// @notice 当受益人为 admin 且其 parent 非 owner 时，解析实际收款地址为上层 admin 的 AA；否则返回原 to
    /// @dev 受益人必须为 AA；通过 AA.owner() 获取 EOA，再以 EOA 检测 admin（admin 以 EOA 登记）
    /// @return effectiveTo 实际转账目标地址
    /// @return beneficiaryAdmin 指定受益人对应的 admin（EOA）；address(0) 表示无需重定向
    /// @return upperAdmin 上层 admin（adminParent[beneficiaryAdmin]）；address(0) 表示无需重定向
    function _resolveTransferRecipientForAdminRedirect(address to)
        internal
        view
        returns (address effectiveTo, address beneficiaryAdmin, address upperAdmin)
    {
        effectiveTo = to;
        beneficiaryAdmin = address(0);
        upperAdmin = address(0);

        // 受益人必须为 AA；从 AA.owner() 获取 EOA，admin 以 EOA 登记
        if (to.code.length == 0) return (to, address(0), address(0));
        (bool ok, bytes memory ret) = to.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return (to, address(0), address(0));
        address eoa = abi.decode(ret, (address));

        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        if (!g.isAdmin[eoa]) return (to, address(0), address(0));
        address parent = g.adminParent[eoa];
        if (parent == address(0)) return (to, address(0), address(0)); // owner 添加的 admin，不重定向

        beneficiaryAdmin = eoa;
        upperAdmin = parent;
        effectiveTo = _toAccount(parent);
    }

    /// @dev 统计以 EOA 为键：每笔 transfer 仅记入一个 admin，避免 aggregate 时 double count
    /// @dev 有 beneficiaryAdmin 时记入接收方；否则记入 operator（发送方）
    function _recordPointTransferStats(address from, address beneficiaryAdmin, address upperAdmin, uint256 count, uint256 amount) internal {
        upperAdmin; // unused
        if (beneficiaryAdmin != address(0)) {
            AdminStatsStorage.recordTransfer(beneficiaryAdmin, count, amount);
            return;
        }
        address operator = _resolveTransferStatsOperator(from);
        if (operator != address(0) && (count > 0 || amount > 0)) {
            AdminStatsStorage.recordTransfer(operator, count, amount);
        }
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
    struct _UpdatePreResult {
        address effectiveTo;
        address beneficiaryAdmin;
        address upperAdmin;
        uint256 pointTransferCount;
        uint256 pointTransferAmount;
        address[] burnedFrom;
        uint256[] burnedIds;
        uint256 burnedCount;
    }

    function _updatePreProcess(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        view
        returns (_UpdatePreResult memory r)
    {
        bool isRealTransfer = (from != address(0) && to != address(0));
        if (isRealTransfer && to.code.length == 0) revert UC_BeneficiaryMustBeAA();

        (r.effectiveTo, r.beneficiaryAdmin, r.upperAdmin) = _resolveTransferRecipientForAdminRedirect(to);
        r.burnedFrom = new address[](ids.length);
        r.burnedIds = new uint256[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (id >= NFT_START_ID && id < ISSUED_NFT_START_ID) {
                if (!(from == address(0) || to == address(0))) revert UC_SBTNonTransferable();
                if (to == address(0) && from != address(0)) {
                    r.burnedFrom[r.burnedCount] = from;
                    r.burnedIds[r.burnedCount] = id;
                    r.burnedCount++;
                }
                continue;
            }
            if (id == POINTS_ID && isRealTransfer) {
                if (values[i] > 0) {
                    r.pointTransferCount += 1;
                    r.pointTransferAmount += values[i];
                }
                if (transferWhitelistEnabled && !transferWhitelist[address(0)] && !transferWhitelist[r.effectiveTo]) {
                    revert UC_PointsToNotWhitelisted();
                }
            }
        }
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        _UpdatePreResult memory r = _updatePreProcess(from, to, ids, values);

        super._update(from, r.effectiveTo, ids, values);

        bool isRealTransfer = (from != address(0) && to != address(0));
        if (isRealTransfer && (r.pointTransferCount > 0 || r.pointTransferAmount > 0)) {
            _recordPointTransferStats(from, r.beneficiaryAdmin, r.upperAdmin, r.pointTransferCount, r.pointTransferAmount);
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
    }

    function _removeNft(address user, uint256 id) internal {
        _callModule(MODULE_MEMBERSHIP_STATS, abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.removeNft.selector, user, id));
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
}
