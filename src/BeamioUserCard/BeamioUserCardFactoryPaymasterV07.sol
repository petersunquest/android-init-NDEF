// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioUserCard.sol";
import "./BeamioCurrency.sol";
import "./BeamioERC1155Logic.sol";
import "./Errors.sol";
import "./FaucetStorage.sol";
import "../contracts/utils/cryptography/ECDSA.sol";
import "../contracts/utils/cryptography/MessageHashUtils.sol";

/* =========================
   Quote helper
   ========================= */
interface IBeamioQuoteHelper {
    function quoteCurrencyAmountInUSDC6(uint8 cur, uint256 amount6) external view returns (uint256);
    function quoteUnitPointInUSDC6(uint8 cardCurrency, uint256 unitPointPriceInCurrencyE6) external view returns (uint256);
}

/* =========================
   Deployer
   ========================= */
interface IBeamioDeployerV07 {
    function deploy(bytes calldata initCode) external returns (address);
}

/**
 * @title BeamioUserCardFactoryPaymasterV07
 * @notice Factory / Gateway / Paymaster router for BeamioUserCard
 * @dev
 *  - USDC address: injected via constructor (no magic constant)
 *  - defaultRedeemModule: injected & upgradable by owner
 *  - aaFactory: injected & upgradable by owner
 */
contract BeamioUserCardFactoryPaymasterV07 is IBeamioFactoryOracle {
    bytes4 private constant MINT_POINTS_BY_ADMIN_SELECTOR = bytes4(keccak256("mintPointsByAdmin(address,uint256)"));

    // ===== immutable chain config =====
    address public immutable USDC_TOKEN;

    // ===== admin =====
    address public owner;
    mapping(address => bool) public isPaymaster;

    // ===== modules / helpers =====
    address public defaultRedeemModule;
    address public defaultFaucetModule;
    address public defaultIssuedNftModule;
    address public defaultGovernanceModule;
    address public defaultMembershipStatsModule;
    address public quoteHelper;
    address public deployer;
    string private _metadataBaseURIValue;

    // AA factory (BeamioAccountFactory)
    address public _aaFactory;

    // ===== id issuance =====
    uint256 public nextFungibleId;
    uint256 public nextNftId;
    mapping(address => mapping(uint256 => bool)) public tokenIdIssued;

    // ===== registry =====
    mapping(address => address[]) private _cardsOfOwner;
    mapping(address => mapping(address => bool)) public isCardOfOwner;
    mapping(address => address) public beamioUserCardOwner;

    // Owner-signed execute: nonce replay protection（通用 executeForOwner）
    mapping(bytes32 => bool) public usedOwnerExecuteNonces;

    // Admin-signed execute: nonce replay protection（executeForAdmin，per card per admin）
    mapping(bytes32 => bool) public usedAdminExecuteNonces;

    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event PaymasterStatusChanged(address indexed account, bool allowed);

    event DefaultRedeemModuleUpdated(address indexed oldM, address indexed newM);
    event DefaultFaucetModuleUpdated(address indexed oldM, address indexed newM);
    event DefaultIssuedNftModuleUpdated(address indexed oldM, address indexed newM);
    event DefaultGovernanceModuleUpdated(address indexed oldM, address indexed newM);
    event DefaultMembershipStatsModuleUpdated(address indexed oldM, address indexed newM);
    event QuoteHelperChanged(address indexed oldH, address indexed newH);
    event DeployerChanged(address indexed oldD, address indexed newD);
    event AAFactoryChanged(address indexed oldFactory, address indexed newFactory);
    event MetadataBaseURIUpdated(string oldURI, string newURI);

    event CardDeployed(address indexed cardOwner, address indexed card, uint8 currency, uint256 priceE18);
    event CardRegistered(address indexed cardOwner, address indexed card);
    /// @notice createCard 失败时标记步骤：0=CREATE 失败，1=gateway，2=owner，3=currency，4=price
    event DeployFailedStep(uint8 step);
    event RedeemExecuted(address indexed card, address indexed user, bytes32 redeemHash);
    event TokenIdIssued(address indexed card, uint256 indexed id, bool isNft);
    event PointsPurchasedForUser(
        address indexed card,
        address indexed fromEOA,
        address indexed cardOwner,
        uint256 usdcAmount6,
        uint256 pointsOut6,
        bytes32 nonce
    );
    event IssuedNftPurchasedForUser(
        address indexed card,
        address indexed userEOA,
        address indexed cardOwner,
        uint256 tokenId,
        uint256 amount,
        uint256 usdcAmount6,
        bytes32 nonce
    );
    event AdminExecuteExecuted(address indexed card, address indexed adminSigner, bytes32 nonce);

    modifier onlyOwner() {
        if (msg.sender != owner) revert BM_NotAuthorized();
        _;
    }

    modifier onlyPaymaster() {
        if (!(msg.sender == owner || isPaymaster[msg.sender])) revert BM_NotAuthorized();
        _;
    }

    constructor(
        address usdcToken_,
        address redeemModule_,
        address quoteHelper_,
        address deployer_,
        address aaFactory_,
        address initialOwner
    ) {
        if (
            usdcToken_ == address(0) ||
            redeemModule_ == address(0) ||
            quoteHelper_ == address(0) ||
            deployer_ == address(0) ||
            aaFactory_ == address(0) ||
            initialOwner == address(0)
        ) revert BM_ZeroAddress();

        USDC_TOKEN = usdcToken_;

        owner = initialOwner;
        isPaymaster[initialOwner] = true;

        defaultRedeemModule = redeemModule_;
        defaultFaucetModule = redeemModule_;      // owner can setFaucetModule to dedicated module
        defaultIssuedNftModule = redeemModule_;
        defaultGovernanceModule = redeemModule_;
        defaultMembershipStatsModule = redeemModule_;
        quoteHelper = quoteHelper_;
        deployer = deployer_;
        _aaFactory = aaFactory_;

        // no magic numbers: align with BeamioERC1155Logic constants
        nextFungibleId = 1;
        nextNftId = BeamioERC1155Logic.NFT_START_ID;

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("BeamioUserCardFactory")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    // ===== IBeamioFactoryOracle =====
    function USDC() external view returns (address) { return USDC_TOKEN; }
    function aaFactory() external view returns (address) { return _aaFactory; }
    function isTokenIdIssued(address card, uint256 id) external view returns (bool) { return tokenIdIssued[card][id]; }

    function quoteCurrencyAmountInUSDC6(uint8 cur, uint256 amount6) external view returns (uint256) {
        return IBeamioQuoteHelper(quoteHelper).quoteCurrencyAmountInUSDC6(cur, amount6);
    }

    function quoteUnitPointInUSDC6(address card) external view returns (uint256) {
        BeamioUserCard c = BeamioUserCard(card);
        return IBeamioQuoteHelper(quoteHelper).quoteUnitPointInUSDC6(uint8(c.currency()), c.pointsUnitPriceInCurrencyE6());
    }

    function metadataBaseURI() external view returns (string memory) {
        return _metadataBaseURIValue;
    }

    // ===== owner->cards view =====
    function cardsOfOwner(address cardOwner) external view returns (address[] memory) {
        return _cardsOfOwner[cardOwner];
    }

    function latestCardOfOwner(address cardOwner) external view returns (address) {
        uint256 n = _cardsOfOwner[cardOwner].length;
        return n == 0 ? address(0) : _cardsOfOwner[cardOwner][n - 1];
    }

    // ===== admin =====
    function setQuoteHelper(address h) external onlyOwner {
        if (h == address(0)) revert BM_ZeroAddress();
        emit QuoteHelperChanged(quoteHelper, h);
        quoteHelper = h;
    }

    function setDeployer(address d) external onlyOwner {
        if (d == address(0)) revert BM_ZeroAddress();
        emit DeployerChanged(deployer, d);
        deployer = d;
    }

    function setRedeemModule(address m) external onlyOwner {
        if (m == address(0)) revert BM_ZeroAddress();
        emit DefaultRedeemModuleUpdated(defaultRedeemModule, m);
        defaultRedeemModule = m;
    }

    function setFaucetModule(address m) external onlyOwner {
        if (m == address(0)) revert BM_ZeroAddress();
        emit DefaultFaucetModuleUpdated(defaultFaucetModule, m);
        defaultFaucetModule = m;
    }

    function setIssuedNftModule(address m) external onlyOwner {
        if (m == address(0)) revert BM_ZeroAddress();
        emit DefaultIssuedNftModuleUpdated(defaultIssuedNftModule, m);
        defaultIssuedNftModule = m;
    }

    function setGovernanceModule(address m) external onlyOwner {
        if (m == address(0)) revert BM_ZeroAddress();
        emit DefaultGovernanceModuleUpdated(defaultGovernanceModule, m);
        defaultGovernanceModule = m;
    }

    function setMembershipStatsModule(address m) external onlyOwner {
        if (m == address(0)) revert BM_ZeroAddress();
        emit DefaultMembershipStatsModuleUpdated(defaultMembershipStatsModule, m);
        defaultMembershipStatsModule = m;
    }

    function setAAFactory(address f) external onlyOwner {
        if (f == address(0)) revert BM_ZeroAddress();
        emit AAFactoryChanged(_aaFactory, f);
        _aaFactory = f;
    }

    /// @notice 更新所有 BeamioUserCard 共享的 metadata base URI；仅工厂 owner 可更新
    function setMetadataBaseURI(string calldata newBaseURI) external onlyOwner {
        _setMetadataBaseURI(newBaseURI);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert BM_ZeroAddress();
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function changePaymasterStatus(address a, bool ok) external onlyOwner {
        isPaymaster[a] = ok;
        emit PaymasterStatusChanged(a, ok);
    }

    // ===== id issuance =====
    function issueTokenId(address card, bool isNft) external onlyPaymaster returns (uint256 id) {
        if (card == address(0) || card.code.length == 0) revert BM_ZeroAddress();
        if (BeamioUserCard(card).factoryGateway() != address(this)) revert BM_NotAuthorized();

        id = isNft ? nextNftId++ : nextFungibleId++;
        tokenIdIssued[card][id] = true;

        emit TokenIdIssued(card, id, isNft);
    }

    // ==========================================================
    // Deploy with initCode (creationCode + abi.encode(args))
    // 失败时 emit DeployFailedStep(step) 并 revert BM_DeployFailedAtStep(step)，便于定位。
    // ==========================================================
    function _deployAndRegisterCard(
        address cardOwner,
        uint8 currency,
        uint256 priceInCurrencyE6,
        bytes calldata initCode
    ) internal returns (address card) {
        if (cardOwner == address(0)) revert BM_ZeroAddress();
        if (initCode.length == 0) revert BM_DeployFailed();

        card = IBeamioDeployerV07(deployer).deploy(initCode);
        if (card == address(0) || card.code.length == 0) {
            emit DeployFailedStep(0); // CREATE 失败（OOG / EIP-170 / EIP-3860 / constructor revert）
            revert BM_DeployFailedAtStep(0);
        }

        // validate
        BeamioUserCard c = BeamioUserCard(card);
        if (c.factoryGateway() != address(this)) {
            emit DeployFailedStep(1);
            revert BM_DeployFailedAtStep(1);
        }
        if (c.owner() != cardOwner) {
            emit DeployFailedStep(2);
            revert BM_DeployFailedAtStep(2);
        }
        if (uint8(c.currency()) != currency) {
            emit DeployFailedStep(3);
            revert BM_DeployFailedAtStep(3);
        }
        if (c.pointsUnitPriceInCurrencyE6() != priceInCurrencyE6) {
            emit DeployFailedStep(4);
            revert BM_DeployFailedAtStep(4);
        }

        _registerCard(cardOwner, card);
        beamioUserCardOwner[card] = cardOwner;

        emit CardDeployed(cardOwner, card, currency, priceInCurrencyE6);
    }

    function createCardCollectionWithInitCode(
        address cardOwner,
        uint8 currency,
        uint256 priceInCurrencyE6,
        bytes calldata initCode
    ) external onlyPaymaster returns (address card) {
        return _deployAndRegisterCard(cardOwner, currency, priceInCurrencyE6, initCode);
    }

    /// @notice 创建卡并一次性配置 tiers（与 createCardCollectionWithInitCode 相同，部署后追加 tiers）
    /// @param tiers BeamioUserCard.Tier 数组，可为空
    function createCardCollectionWithInitCodeAndTiers(
        address cardOwner,
        uint8 currency,
        uint256 priceInCurrencyE6,
        bytes calldata initCode,
        BeamioUserCard.Tier[] calldata tiers
    ) external onlyPaymaster returns (address card) {
        card = _deployAndRegisterCard(cardOwner, currency, priceInCurrencyE6, initCode);
        BeamioUserCard c = BeamioUserCard(card);
        for (uint256 i = 0; i < tiers.length; i++) {
            BeamioUserCard.Tier memory t = tiers[i];
            if (t.minUsdc6 == 0) revert UC_TierMinZero();
            c.appendTier(t.minUsdc6, t.attr, t.tierExpirySeconds, t.upgradeByBalance);
        }
    }

    function isBeamioUserCard(address card) external view returns (bool) {
        return beamioUserCardOwner[card] != address(0);
    }

    function registerExistingCard(address cardOwner, address card) external onlyPaymaster {
        if (cardOwner == address(0) || card == address(0)) revert BM_ZeroAddress();
        if (isCardOfOwner[cardOwner][card]) revert F_AlreadyRegistered();

        BeamioUserCard c = BeamioUserCard(card);
        if (c.factoryGateway() != address(this)) revert F_BadDeployedCard();
        if (c.owner() != cardOwner) revert F_BadDeployedCard();

        _registerCard(cardOwner, card);
        beamioUserCardOwner[card] = cardOwner;

        emit CardRegistered(cardOwner, card);
    }

    function _registerCard(address cardOwner, address card) internal {
        isCardOfOwner[cardOwner][card] = true;
        _cardsOfOwner[cardOwner].push(card);
    }

    function _setMetadataBaseURI(string memory newBaseURI) internal {
        if (bytes(newBaseURI).length == 0) revert BM_ZeroAddress();
        string memory oldURI = _metadataBaseURIValue;
        _metadataBaseURIValue = newBaseURI;
        emit MetadataBaseURIUpdated(oldURI, newBaseURI);
    }

    // ==========================================================
    // Paymaster route: consume redeem for user (gas sponsored offchain)
    // ==========================================================
    function redeemForUser(address cardAddr, string calldata code, address userEOA) external onlyPaymaster {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (cardAddr == address(0) || cardAddr.code.length == 0) revert BM_ZeroAddress();
        if (BeamioUserCard(cardAddr).factoryGateway() != address(this)) revert BM_NotAuthorized();

        if (bytes(code).length == 0) revert F_InvalidRedeemHash();

        BeamioUserCard(cardAddr).redeemByGateway(code, userEOA);
        emit RedeemExecuted(cardAddr, userEOA, keccak256(bytes(code)));
    }

    /// @notice 批量 one-time redeem（多张相同类型）
    function redeemBatchForUser(address cardAddr, string[] calldata codes, address userEOA) external onlyPaymaster {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (cardAddr == address(0) || cardAddr.code.length == 0) revert BM_ZeroAddress();
        if (BeamioUserCard(cardAddr).factoryGateway() != address(this)) revert BM_NotAuthorized();
        if (codes.length == 0) revert F_InvalidRedeemHash();

        BeamioUserCard(cardAddr).redeemBatchByGateway(codes, userEOA);
        for (uint256 i = 0; i < codes.length; i++) {
            emit RedeemExecuted(cardAddr, userEOA, keccak256(bytes(codes[i])));
        }
    }

    function redeemPoolForUser(address cardAddr, string calldata code, address userEOA) external onlyPaymaster {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (cardAddr == address(0) || cardAddr.code.length == 0) revert BM_ZeroAddress();
        if (BeamioUserCard(cardAddr).factoryGateway() != address(this)) revert BM_NotAuthorized();

        if (bytes(code).length == 0) revert F_InvalidRedeemHash();

        BeamioUserCard(cardAddr).redeemPoolByGateway(code, userEOA);
        emit RedeemExecuted(cardAddr, userEOA, keccak256(bytes(code)));
    }

    /// @notice Gateway 为卡追加 tier（createCard 后由 paymaster 调用，用于配置 tiers）
    /// @dev 卡合约 appendTier 需 owner 或 gateway；Factory 为 gateway，故可代调
    function appendTierForCard(
        address cardAddr,
        uint256 minUsdc6,
        uint256 attr,
        uint256 tierExpirySeconds,
        bool upgradeByBalance
    ) external onlyPaymaster {
        if (cardAddr == address(0) || cardAddr.code.length == 0) revert BM_ZeroAddress();
        if (BeamioUserCard(cardAddr).factoryGateway() != address(this)) revert BM_NotAuthorized();
        BeamioUserCard(cardAddr).appendTier(minUsdc6, attr, tierExpirySeconds, upgradeByBalance);
    }

    /// @notice Owner 离线签名授权 appendTier，由 paymaster 代付 gas 执行。复用 executeForOwner 的 EIP-712 验签。
    /// @param deadline 签名过期时间戳
    /// @param nonce 防重放，需唯一
    function appendTierForCardWithOwnerSignature(
        address cardAddr,
        uint256 minUsdc6,
        uint256 attr,
        uint256 tierExpirySeconds,
        bool upgradeByBalance,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata ownerSignature
    ) external onlyPaymaster {
        bytes memory data = abi.encodeWithSelector(
            BeamioUserCard.appendTier.selector,
            minUsdc6,
            attr,
            tierExpirySeconds,
            upgradeByBalance
        );
        _executeForOwner(cardAddr, data, deadline, nonce, ownerSignature);
    }

    // ==========================================================
    // Buy points for user (USDC ERC-3009 -> merchant, then mint points)
    // 资金流集中入口：用户 USDC 直接到 merchant，gas 由 paymaster 代付
    // ==========================================================
    uint256 private constant POINTS_ONE = 1e6;

    function buyPointsForUser(
        address cardAddr,
        address fromEOA,
        uint256 usdcAmount6,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature,
        uint256 minPointsOut6
    ) external onlyPaymaster returns (uint256 pointsOut6) {
        if (fromEOA == address(0)) revert BM_ZeroAddress();
        if (cardAddr == address(0) || cardAddr.code.length == 0) revert BM_ZeroAddress();
        if (BeamioUserCard(cardAddr).factoryGateway() != address(this)) revert BM_NotAuthorized();
        if (usdcAmount6 == 0) revert UC_AmountZero();

        address cardOwner = BeamioUserCard(cardAddr).owner();
        if (cardOwner == address(0)) revert BM_ZeroAddress();

        uint256 unitPriceUsdc6 = this.quoteUnitPointInUSDC6(cardAddr);
        if (unitPriceUsdc6 == 0) revert UC_PriceZero();

        pointsOut6 = (usdcAmount6 * POINTS_ONE) / unitPriceUsdc6;
        if (pointsOut6 == 0) revert UC_PointsZero();
        if (pointsOut6 < minPointsOut6) revert UC_Slippage();

        // 1) USDC: fromEOA -> cardOwner (merchant)，资金不经过 paymaster/card
        IERC3009BytesSig(USDC_TOKEN).transferWithAuthorization(
            fromEOA, cardOwner, usdcAmount6, validAfter, validBefore, nonce, signature
        );

        // 2) Card: mint points to user's AA account
        BeamioUserCard(cardAddr).mintPointsByGateway(fromEOA, pointsOut6);

        emit PointsPurchasedForUser(cardAddr, fromEOA, cardOwner, usdcAmount6, pointsOut6, nonce);
        return pointsOut6;
    }

    // ==========================================================
    // Purchase paid faucet for user (USDC ERC-3009 -> merchant, then mint faucet tokens)
    // ==========================================================
    function purchaseFaucetForUser(
        address cardAddr,
        address userEOA,
        uint256 id,
        uint256 amount6,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external onlyPaymaster {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (cardAddr == address(0) || cardAddr.code.length == 0) revert BM_ZeroAddress();
        if (BeamioUserCard(cardAddr).factoryGateway() != address(this)) revert BM_NotAuthorized();
        if (amount6 == 0) revert UC_AmountZero();

        BeamioUserCard card = BeamioUserCard(cardAddr);
        address cardOwner = card.owner();
        if (cardOwner == address(0)) revert BM_ZeroAddress();

        FaucetStorage.FaucetConfig memory cfg = card.faucetConfig(id);
        if (!cfg.enabled) revert UC_FaucetNotEnabled();
        if (cfg.priceInCurrency6 == 0) revert UC_PurchaseDisabledBecauseFree();

        uint256 amountInCurrency6 = (uint256(cfg.priceInCurrency6) * amount6) / POINTS_ONE;
        uint256 usdcAmount6 = this.quoteCurrencyAmountInUSDC6(cfg.currency, amountInCurrency6);

        // 1) USDC: userEOA -> cardOwner (merchant)
        IERC3009BytesSig(USDC_TOKEN).transferWithAuthorization(
            userEOA, cardOwner, usdcAmount6, validAfter, validBefore, nonce, signature
        );

        // 2) Card: mint faucet tokens to user's AA account
        card.mintFaucetByGateway(userEOA, id, amount6);
    }

    // ==========================================================
    // Purchase issued NFT for user (USDC ERC-3009 -> merchant, then mint issued NFT)
    // ==========================================================
    function purchaseIssuedNftForUser(
        address cardAddr,
        address userEOA,
        uint256 tokenId,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external onlyPaymaster {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (cardAddr == address(0) || cardAddr.code.length == 0) revert BM_ZeroAddress();
        if (BeamioUserCard(cardAddr).factoryGateway() != address(this)) revert BM_NotAuthorized();
        if (amount == 0) revert UC_AmountZero();

        BeamioUserCard card = BeamioUserCard(cardAddr);
        address cardOwner = card.owner();
        if (cardOwner == address(0)) revert BM_ZeroAddress();

        uint256 priceInCurrency6 = card.issuedNftPriceInCurrency6(tokenId);
        if (priceInCurrency6 == 0) revert UC_PurchaseDisabledBecauseFree();

        uint256 totalPriceInCurrency6 = amount * priceInCurrency6;
        uint256 usdcAmount6 = this.quoteCurrencyAmountInUSDC6(uint8(card.currency()), totalPriceInCurrency6);
        if (usdcAmount6 == 0) revert UC_AmountZero();

        // 1) USDC: userEOA -> cardOwner (merchant)
        IERC3009BytesSig(USDC_TOKEN).transferWithAuthorization(
            userEOA, cardOwner, usdcAmount6, validAfter, validBefore, nonce, signature
        );

        // 2) Card: mint issued NFT to user's AA account
        card.mintIssuedNftByGateway(userEOA, tokenId, amount);

        emit IssuedNftPurchasedForUser(cardAddr, userEOA, cardOwner, tokenId, amount, usdcAmount6, nonce);
    }

    bytes32 public constant EXECUTE_FOR_OWNER_TYPEHASH = keccak256(
        "ExecuteForOwner(address cardAddress,bytes32 dataHash,uint256 deadline,bytes32 nonce)"
    );
    bytes32 public constant EXECUTE_FOR_ADMIN_TYPEHASH = keccak256(
        "ExecuteForAdmin(address cardAddress,bytes32 dataHash,uint256 deadline,bytes32 nonce)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @dev 内部：验签并执行 owner 签名的 calldata
    function _executeForOwner(
        address cardAddr,
        bytes memory data,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata ownerSignature
    ) internal {
        if (cardAddr == address(0) || cardAddr.code.length == 0) revert BM_ZeroAddress();
        if (data.length == 0) revert F_InvalidRedeemHash();
        if (block.timestamp > deadline) revert UC_InvalidTimeWindow(block.timestamp, 0, deadline);
        if (BeamioUserCard(cardAddr).factoryGateway() != address(this)) revert BM_NotAuthorized();

        address cardOwner = BeamioUserCard(cardAddr).owner();

        bytes32 structHash = keccak256(abi.encode(
            EXECUTE_FOR_OWNER_TYPEHASH,
            cardAddr,
            keccak256(data),
            deadline,
            nonce
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        address signer = ECDSA.recover(digest, ownerSignature);
        if (signer != cardOwner) revert UC_InvalidSignature(signer, cardOwner);

        bytes32 nonceKey = keccak256(abi.encode(cardAddr, nonce));
        if (usedOwnerExecuteNonces[nonceKey]) revert UC_NonceUsed();
        usedOwnerExecuteNonces[nonceKey] = true;

        (bool ok, bytes memory revertData) = cardAddr.call(data);
        if (!ok) {
            if (revertData.length > 0) {
                assembly { revert(add(revertData, 32), mload(revertData)) }
            }
            revert BM_CallFailed();
        }
    }

    /// @notice 通用：Owner 离线签名授权对 card 的任意调用，由 paymaster 代付 gas 执行。支持 createRedeem、cancelRedeem 等。
    /// @param data abi.encodeWithSelector(selector, ...args)，如 createRedeem(hash, points6, ...)
    function executeForOwner(
        address cardAddr,
        bytes calldata data,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata ownerSignature
    ) external onlyPaymaster {
        _executeForOwner(cardAddr, bytes(data), deadline, nonce, ownerSignature);
    }

    /// @notice 通用：Card Admin 离线签名授权对 card 的调用（如 mint），由 paymaster 代付 gas 执行。
    /// @param data abi.encodeWithSelector(selector, ...args)，仅允许 mintPointsByAdmin(target, points6)（topup）
    /// @dev 验签在 Factory 内完成；恢复的 signer 必须为 card.isAdmin(signer)
    function executeForAdmin(
        address cardAddr,
        bytes calldata data,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata adminSignature
    ) external onlyPaymaster {
        if (cardAddr == address(0) || cardAddr.code.length == 0) revert BM_ZeroAddress();
        if (data.length < 4) revert F_InvalidRedeemHash();
        if (block.timestamp > deadline) revert UC_InvalidTimeWindow(block.timestamp, 0, deadline);
        if (BeamioUserCard(cardAddr).factoryGateway() != address(this)) revert BM_NotAuthorized();
        bytes4 selector = bytes4(data[:4]);
        if (selector != MINT_POINTS_BY_ADMIN_SELECTOR) revert UC_InvalidProposal();

        bytes32 structHash = keccak256(abi.encode(
            EXECUTE_FOR_ADMIN_TYPEHASH,
            cardAddr,
            keccak256(data),
            deadline,
            nonce
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        address signer = ECDSA.recover(digest, adminSignature);
        if (!BeamioUserCard(cardAddr).isAdmin(signer)) revert UC_NotAdmin();

        bytes32 nonceKey = keccak256(abi.encode(cardAddr, signer, nonce));
        if (usedAdminExecuteNonces[nonceKey]) revert UC_NonceUsed();
        usedAdminExecuteNonces[nonceKey] = true;

        (bool ok, bytes memory revertData) = cardAddr.call(data);
        if (!ok) {
            if (revertData.length > 0) {
                assembly { revert(add(revertData, 32), mload(revertData)) }
            }
            revert BM_CallFailed();
        }
        emit AdminExecuteExecuted(cardAddr, signer, nonce);
    }
}
