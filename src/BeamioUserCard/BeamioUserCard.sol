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
    function metadataBaseURI() external view returns (string memory);
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
    function addAdmin(address newAdmin, uint256 newThreshold) external;
    function removeAdmin(address adminToRemove, uint256 newThreshold) external;
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
    uint256 public constant VERSION = 11;

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

    // -------- Faucet / IssuedNFT / Governance views (from delegatecall storage) --------
    function faucetConfig(uint256 id) public view returns (FaucetStorage.FaucetConfig memory) {
        return FaucetStorage.layout().faucetConfig[id];
    }

    function issuedNftIndex() external view returns (uint256) {
        return IssuedNftStorage.layout().issuedNftIndex;
    }
    function issuedNftValidAfter(uint256 tokenId) external view returns (uint64) { return IssuedNftStorage.layout().issuedNftValidAfter[tokenId]; }
    function issuedNftValidBefore(uint256 tokenId) external view returns (uint64) { return IssuedNftStorage.layout().issuedNftValidBefore[tokenId]; }
    function issuedNftTitle(uint256 tokenId) external view returns (bytes32) { return IssuedNftStorage.layout().issuedNftTitle[tokenId]; }
    function issuedNftSharedMetadataHash(uint256 tokenId) external view returns (bytes32) { return IssuedNftStorage.layout().issuedNftSharedMetadataHash[tokenId]; }
    function issuedNftMaxSupply(uint256 tokenId) external view returns (uint256) { return IssuedNftStorage.layout().issuedNftMaxSupply[tokenId]; }
    function issuedNftMintedCount(uint256 tokenId) external view returns (uint256) { return IssuedNftStorage.layout().issuedNftMintedCount[tokenId]; }
    function issuedNftPriceInCurrency6(uint256 tokenId) external view returns (uint256) { return IssuedNftStorage.layout().issuedNftPriceInCurrency6[tokenId]; }

    function threshold() public view returns (uint256) { return GovernanceStorage.layout().threshold; }
    function isAdmin(address a) public view returns (bool) { return GovernanceStorage.layout().isAdmin[a]; }
    function adminList(uint256 i) external view returns (address) { return GovernanceStorage.layout().adminList[i]; }
    function proposalCount() external view returns (uint256) { return GovernanceStorage.layout().proposalCount; }
    function proposals(uint256 id) external view returns (GovernanceStorage.Proposal memory) { return GovernanceStorage.layout().proposals[id]; }

    // ==========================================================
    // Faucet config (delegatecall)
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
        _callModule(
            MODULE_FAUCET,
            abi.encodeWithSelector(
                IBeamioFaucetModuleV1.setFaucetConfig.selector,
                id,
                validUntil,
                perClaimMax,
                maxPerUser,
                maxGlobal,
                enabled,
                uint8(cur),
                priceInCurrency6
            )
        );
        emit FaucetConfigUpdated(id, FaucetStorage.layout().faucetConfig[id]);
    }

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
        if (!hasValidCard) _issueCardByPointsDelta_AssumingNoValidCard(acct, pointsDelta6);
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
            _maybeIssueOnlyIfNoneOrExpiredByPointsDelta(acct, pointsDelta6);
            _maybeUpgrade(acct, pointsDelta6);
        }
        emit FaucetClaimed(outId, userEOA, acct, outAmount, FaucetStorage.layout().faucetClaimed[outId][userEOA]);
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
        _callModule(
            MODULE_REDEEM,
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
        _callModule(
            MODULE_REDEEM,
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
        _callModule(MODULE_REDEEM, abi.encodeWithSelector(IBeamioRedeemModuleVNext.cancelRedeem.selector, code));
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
        _callModule(
            MODULE_REDEEM,
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
    }

    /// @notice card owner (or gateway) terminates pool
    function terminateRedeemPool(bytes32 poolHash) external nonReentrant {
        _requireOwnerOrGateway();
        _callModule(MODULE_REDEEM, abi.encodeWithSelector(IBeamioRedeemModuleVNext.terminateRedeemPool.selector, poolHash));
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
        else _maybeUpgrade(acct, totalPoints6);
    }

    /// @notice gateway consumes batch one-time redeem (multiple codes of same type) and mints to user's AA account
    function redeemBatchByGateway(string[] calldata codes, address userEOA)
        external
        onlyAuthorizedGateway
        nonReentrant
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (codes.length == 0) revert UC_InvalidProposal();
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
        else _maybeUpgrade(acct, totalPoints6);
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
        _maybeUpgrade(acct, points6);

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
        _maybeUpgrade(acct, points6);
        emit AdminPointsMinted(acct, points6);
    }

    function _addAdmin(address newAdmin, uint256 newThreshold) internal {
        if (newAdmin == address(0)) revert BM_ZeroAddress();
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        if (!l.isAdmin[newAdmin]) {
            l.isAdmin[newAdmin] = true;
            l.adminList.push(newAdmin);
        }
        if (newThreshold > l.adminList.length) revert UC_InvalidProposal();
        l.threshold = newThreshold;
    }

    function _removeAdmin(address adminToRemove, uint256 newThreshold) internal {
        if (adminToRemove == address(0)) revert BM_ZeroAddress();
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        if (!l.isAdmin[adminToRemove]) revert UC_InvalidProposal();
        if (l.adminList.length <= 1) revert UC_InvalidProposal();

        l.isAdmin[adminToRemove] = false;
        bool found = false;
        uint256 n = l.adminList.length;
        for (uint256 i = 0; i < n; i++) {
            if (l.adminList[i] == adminToRemove) {
                l.adminList[i] = l.adminList[n - 1];
                l.adminList.pop();
                found = true;
                break;
            }
        }
        if (!found) revert UC_InvalidProposal();
        if (newThreshold == 0 || newThreshold > l.adminList.length) revert UC_InvalidProposal();
        l.threshold = newThreshold;
    }

    function addAdmin(address newAdmin, uint256 newThreshold) public {
        _requireOwnerOrGateway();
        address module = _module(MODULE_GOVERNANCE);
        (bool ok,) = module.delegatecall(abi.encodeWithSelector(IBeamioGovernanceModuleV1.addAdmin.selector, newAdmin, newThreshold));
        if (!ok) revert UC_InvalidProposal();
    }

    function removeAdmin(address adminToRemove, uint256 newThreshold) public {
        _requireOwnerOrGateway();
        address module = _module(MODULE_GOVERNANCE);
        (bool ok,) = module.delegatecall(
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.removeAdmin.selector, adminToRemove, newThreshold)
        );
        if (!ok) revert UC_InvalidProposal();
    }

    function _executeWith(bytes4 sel, address target, uint256 v1, uint256 v2, uint256 /* v3 */) internal {
        if (sel == bytes4(keccak256("addAdmin(address,uint256)"))) {
            _addAdmin(target, v1);
        } else if (sel == bytes4(keccak256("removeAdmin(address,uint256)"))) {
            _removeAdmin(target, v1);
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
        _mintMemberCardInternal(user, tierIndex);
    }

    /// @notice 定义一个新的「发行 NFT」类型（不指定受益人、不 mint）。如：2月3日14:00 门票100张，单价 10 USDC
    function createIssuedNft(
        bytes32 title,
        uint64 validAfter,
        uint64 validBefore,
        uint256 maxSupply,
        uint256 priceInCurrency6,
        bytes32 sharedMetadataHash
    ) external nonReentrant returns (uint256 tokenId) {
        _requireOwnerOrGateway();
        bytes memory data = _callModule(
            MODULE_ISSUED_NFT,
            abi.encodeWithSelector(
                IBeamioIssuedNftModuleV1.createIssuedNft.selector,
                title,
                validAfter,
                validBefore,
                maxSupply,
                priceInCurrency6,
                sharedMetadataHash
            )
        );
        tokenId = abi.decode(data, (uint256));
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

    // ==========================================================
    // ERC1155 update hook
    // ==========================================================
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        bool isRealTransfer = (from != address(0) && to != address(0));
        address[] memory burnedFrom = new address[](ids.length);
        uint256[] memory burnedIds = new uint256[](ids.length);
        uint256 burnedCount = 0;

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];

            if (id >= NFT_START_ID && id < ISSUED_NFT_START_ID) {
                if (!(from == address(0) || to == address(0))) revert UC_SBTNonTransferable();
                if (to == address(0) && from != address(0)) {
                    burnedFrom[burnedCount] = from;
                    burnedIds[burnedCount] = id;
                    burnedCount++;
                }
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

        if (from == address(0)) {
            TotalSupplyStorage.Layout storage ts = TotalSupplyStorage.layout();
            uint256 totalMintValue = 0;
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 value = values[i];
                ts.totalSupplyById[ids[i]] += value;
                totalMintValue += value;
            }
            ts.totalSupplyAll += totalMintValue;
        }

        if (to == address(0)) {
            TotalSupplyStorage.Layout storage ts = TotalSupplyStorage.layout();
            uint256 totalBurnValue = 0;
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 value = values[i];
                unchecked {
                    ts.totalSupplyById[ids[i]] -= value;
                    totalBurnValue += value;
                }
            }
            unchecked {
                ts.totalSupplyAll -= totalBurnValue;
            }
        }

        for (uint256 i = 0; i < burnedCount; i++) {
            _removeNft(burnedFrom[i], burnedIds[i]);
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

    function exists(uint256 id) external view returns (bool) {
        return TotalSupplyStorage.layout().totalSupplyById[id] > 0;
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
