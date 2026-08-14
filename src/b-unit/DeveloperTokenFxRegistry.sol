// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title DeveloperTokenFxRegistry
 * @notice CoNET-only registry: treasury-issued developer ERC20 ↔ GB FX + 1:1 Settlement NFT#.
 *
 * Registration gate:
 *  - **Only Treasury or DeveloperFxIssuer** may call `registerDeveloperApp` / `registerToken`.
 *  - Token must be TreasuryBridgeV3-managed (Canonical).
 *  - `gbPerFullToken` must be **strictly greater** than CoNET baseline (`minGbPerFullToken`, default 1e9).
 *  - Token CNET stake must stay ≥ Issuer min (else settle burns revert as unqualified).
 *  - Exactly one Settlement NFT# per ERC20 (Settlement bind by Issuer in the same issue tx).
 *
 * Settle modes (DepinGbSettlement1155):
 *  - PayByUse: burn **user** FX tokens (whole-token ceil) → mint GB; miner takes usage; surplus GB → ERC20 contract.
 *  - Subscription: burn **issuer** FX prepaid for exact usage GB; customer not charged.
 *
 * Canonical mint authority:
 *  - Registry holds **BURN_ROLE only** on Canonical (settle burns).
 *  - GB → Canonical mint goes through TreasuryBridgeV3.mintDeveloperFxFromRegistry (treasury is minter).
 */

interface IGBTokenFx {
    function mintPaid(address to, uint256 amount) external;

    function burnPaidFrom(address account, uint256 amount) external;

    function decimals() external view returns (uint8);
}

interface IERC20Meta {
    function decimals() external view returns (uint8);

    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IERC20BurnFrom {
    function burnFrom(address account, uint256 amount) external;
}

interface ITreasuryMintDeveloperFx {
    function mintDeveloperFxFromRegistry(address token, address to, uint256 amount) external;
}

interface ITreasuryAssetKindView {
    function treasuryAssetKind(address asset) external view returns (uint8);
}

interface IDeveloperTokenStakeRegistry {
    function isTreasuryQualified() external view returns (bool);
}

contract DeveloperTokenFxRegistry is Initializable, UUPSUpgradeable {
    /// @dev TreasuryAssetKind.None on TreasuryBridgeV3.
    uint8 private constant TREASURY_KIND_NONE = 0;

    struct TokenConfig {
        bool exists;
        bool enabled;
        uint8 tokenDecimals;
        /// @dev GB min-units (1e9 = 1 GB) credited per 1 full developer token (10**tokenDecimals wei).
        uint256 gbPerFullToken;
        address developer;
    }

    IGBTokenFx public gbToken;
    address public settlement;
    mapping(address => bool) public admins;
    mapping(address => TokenConfig) public tokens;

    /// @dev TreasuryBridgeV3 — `treasuryAssetKind(token) != None` required to register.
    address public treasury;
    /// @dev DeveloperFxIssuer — may register alongside treasury.
    address public fxIssuer;
    /// @dev CoNET baseline; developer FX must be **strictly greater** (e.g. 1e9 → require > 1 GB per full token).
    uint256 public minGbPerFullToken;
    /// @dev Next Settlement NFT# to assign (starts at 1; TGB5 may bind existing #5 via bindExistingTokenPass).
    uint256 public nextPassId;
    mapping(address => uint256) public tokenToPassId;
    mapping(uint256 => address) public passIdToToken;

    uint256[34] private __gap;

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event GbTokenSet(address indexed gbToken);
    event SettlementSet(address indexed settlement);
    event TreasurySet(address indexed treasury);
    event FxIssuerSet(address indexed fxIssuer);
    event MinGbPerFullTokenSet(uint256 minGbPerFullToken);
    event TokenRegistered(
        address indexed token, address indexed developer, uint8 tokenDecimals, uint256 gbPerFullToken, bool enabled
    );
    event TokenEnabled(address indexed token, bool enabled);
    event RateUpdated(address indexed token, uint256 gbPerFullToken);
    event DeveloperAppRegistered(
        address indexed token,
        address indexed developer,
        uint256 indexed passTokenId,
        uint256 gbPerFullToken,
        uint8 passKind,
        uint64 expiresAt
    );
    event TokenPassBound(address indexed token, uint256 indexed passTokenId);
    event DeveloperBurnedForGb(
        address indexed user, address indexed token, address indexed settlement, uint256 tokenBurned, uint256 gbMinted
    );
    event GbBurnedForDeveloper(address indexed user, address indexed token, uint256 gbBurned, uint256 tokenMinted);

    error ZeroAddress();
    error Unauthorized();
    error InvalidConfig();
    error TokenNotRegistered();
    error TokenDisabled();
    error TransferFailed();
    error NotTreasuryManaged();
    error RateNotAboveBaseline();
    error TokenAlreadyLinked();
    error PassAlreadyLinked();
    error DeveloperTokenUnqualified();

    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyTreasuryOrIssuer() {
        if (msg.sender != treasury && msg.sender != fxIssuer) revert Unauthorized();
        if (msg.sender == address(0)) revert Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin, address gbToken_, address settlement_) external initializer {
        if (initialAdmin == address(0) || gbToken_ == address(0) || settlement_ == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        admins[initialAdmin] = true;
        emit AdminAdded(initialAdmin);
        gbToken = IGBTokenFx(gbToken_);
        emit GbTokenSet(gbToken_);
        settlement = settlement_;
        emit SettlementSet(settlement_);
        minGbPerFullToken = 1e9;
        emit MinGbPerFullTokenSet(1e9);
        nextPassId = 1;
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function addAdmin(address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        admins[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyAdmin {
        admins[account] = false;
        emit AdminRemoved(account);
    }

    function setGbToken(address gbToken_) external onlyAdmin {
        if (gbToken_ == address(0)) revert ZeroAddress();
        gbToken = IGBTokenFx(gbToken_);
        emit GbTokenSet(gbToken_);
    }

    function setSettlement(address settlement_) external onlyAdmin {
        if (settlement_ == address(0)) revert ZeroAddress();
        settlement = settlement_;
        emit SettlementSet(settlement_);
    }

    function setTreasury(address treasury_) external onlyAdmin {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setFxIssuer(address fxIssuer_) external onlyAdmin {
        if (fxIssuer_ == address(0)) revert ZeroAddress();
        fxIssuer = fxIssuer_;
        emit FxIssuerSet(fxIssuer_);
    }

    function setMinGbPerFullToken(uint256 minGbPerFullToken_) external onlyAdmin {
        if (minGbPerFullToken_ == 0) revert InvalidConfig();
        minGbPerFullToken = minGbPerFullToken_;
        emit MinGbPerFullTokenSet(minGbPerFullToken_);
    }

    function setNextPassId(uint256 nextPassId_) external onlyAdmin {
        nextPassId = nextPassId_;
    }

    function _requireTreasuryManaged(address token) internal view {
        if (treasury == address(0)) revert InvalidConfig();
        uint8 kind = ITreasuryAssetKindView(treasury).treasuryAssetKind(token);
        if (kind == TREASURY_KIND_NONE) revert NotTreasuryManaged();
    }

    function _requireRateAboveBaseline(uint256 gbPerFullToken) internal view {
        if (gbPerFullToken <= minGbPerFullToken) revert RateNotAboveBaseline();
    }

    /// @dev Stake-gated developer FX: below treasury min CNET stake → refuse settle / mint paths.
    function _requireDeveloperFxQualified(address token) internal view {
        if (!IDeveloperTokenStakeRegistry(token).isTreasuryQualified()) {
            revert DeveloperTokenUnqualified();
        }
    }

    /**
     * @notice Treasury-only: register Canonical FX + allocate 1:1 Settlement NFT# (no Settlement write).
     * @dev Caller must be TreasuryBridgeV3; Treasury then calls Settlement.registerFxPassFromTreasury
     *      in the same `issueDeveloperFxAndRegister` transaction.
     * @param kind Settlement pass kind: 2=PayByUse, 3=Subscription, 4=Dual (recorded in event only here).
     */
    function registerDeveloperApp(
        address token,
        address developer,
        uint256 gbPerFullToken,
        uint64 expiresAt,
        uint8 kind,
        bool enabled
    ) external onlyTreasuryOrIssuer returns (uint256 passTokenId) {
        if (token == address(0) || developer == address(0)) revert ZeroAddress();
        if (expiresAt == 0) revert InvalidConfig();
        _requireTreasuryManaged(token);
        _requireRateAboveBaseline(gbPerFullToken);
        if (tokenToPassId[token] != 0) revert TokenAlreadyLinked();

        uint8 dec = IERC20Meta(token).decimals();
        tokens[token] = TokenConfig({
            exists: true,
            enabled: enabled,
            tokenDecimals: dec,
            gbPerFullToken: gbPerFullToken,
            developer: developer
        });
        emit TokenRegistered(token, developer, dec, gbPerFullToken, enabled);

        passTokenId = nextPassId;
        unchecked {
            ++nextPassId;
        }
        if (passIdToToken[passTokenId] != address(0)) revert PassAlreadyLinked();
        tokenToPassId[token] = passTokenId;
        passIdToToken[passTokenId] = token;

        emit DeveloperAppRegistered(token, developer, passTokenId, gbPerFullToken, kind, expiresAt);
    }

    /**
     * @notice Migrate already-registered token ↔ existing Settlement NFT# (e.g. TGB5 ↔ #5).
     * @dev Does not re-configure Settlement; caller must configurePass / registerFxPass separately if needed.
     */
    function bindExistingTokenPass(address token, uint256 passTokenId) external onlyAdmin {
        TokenConfig storage cfg = tokens[token];
        if (!cfg.exists) revert TokenNotRegistered();
        if (passTokenId == 0) revert InvalidConfig();
        if (tokenToPassId[token] != 0 && tokenToPassId[token] != passTokenId) revert TokenAlreadyLinked();
        if (passIdToToken[passTokenId] != address(0) && passIdToToken[passTokenId] != token) {
            revert PassAlreadyLinked();
        }
        tokenToPassId[token] = passTokenId;
        passIdToToken[passTokenId] = token;
        if (passTokenId >= nextPassId) {
            nextPassId = passTokenId + 1;
        }
        emit TokenPassBound(token, passTokenId);
    }

    /**
     * @dev Treasury-only FX rate row without allocating a new NFT# (migration / repair).
     *      Prefer `registerDeveloperApp` via Treasury.issueDeveloperFxAndRegister.
     */
    function registerToken(address token, address developer, uint256 gbPerFullToken, bool enabled)
        external
        onlyTreasuryOrIssuer
    {
        if (token == address(0) || developer == address(0)) revert ZeroAddress();
        _requireTreasuryManaged(token);
        _requireRateAboveBaseline(gbPerFullToken);
        uint8 dec = IERC20Meta(token).decimals();
        tokens[token] = TokenConfig({
            exists: true,
            enabled: enabled,
            tokenDecimals: dec,
            gbPerFullToken: gbPerFullToken,
            developer: developer
        });
        emit TokenRegistered(token, developer, dec, gbPerFullToken, enabled);
    }

    function setTokenEnabled(address token, bool enabled) external onlyAdmin {
        TokenConfig storage cfg = tokens[token];
        if (!cfg.exists) revert TokenNotRegistered();
        cfg.enabled = enabled;
        emit TokenEnabled(token, enabled);
    }

    function setRate(address token, uint256 gbPerFullToken) external onlyAdmin {
        TokenConfig storage cfg = tokens[token];
        if (!cfg.exists) revert TokenNotRegistered();
        _requireRateAboveBaseline(gbPerFullToken);
        cfg.gbPerFullToken = gbPerFullToken;
        emit RateUpdated(token, gbPerFullToken);
    }

    /// @notice Token wei required to mint `gbAmount` GB min-units (ceil).
    function quoteTokenIn(address token, uint256 gbAmount) public view returns (uint256 tokenIn) {
        TokenConfig memory cfg = tokens[token];
        if (!cfg.exists) revert TokenNotRegistered();
        if (gbAmount == 0) return 0;
        uint256 full = 10 ** uint256(cfg.tokenDecimals);
        tokenIn = (gbAmount * full + cfg.gbPerFullToken - 1) / cfg.gbPerFullToken;
    }

    /// @notice GB min-units for `tokenAmount` wei (floor).
    function quoteGbOut(address token, uint256 tokenAmount) public view returns (uint256 gbOut) {
        TokenConfig memory cfg = tokens[token];
        if (!cfg.exists) revert TokenNotRegistered();
        if (tokenAmount == 0) return 0;
        uint256 full = 10 ** uint256(cfg.tokenDecimals);
        gbOut = (tokenAmount * cfg.gbPerFullToken) / full;
    }

    /**
     * @notice Burn developer tokens from `user` for exact `gbAmount` coverage (ceil wei) and mintPaid to Settlement.
     * @dev Subscription path: typically `user` = issuer.
     */
    function burnDeveloperMintGbToSettlement(address user, address token, uint256 gbAmount)
        external
        returns (uint256 tokenBurned)
    {
        if (msg.sender != settlement && !admins[msg.sender]) revert Unauthorized();
        if (user == address(0) || gbAmount == 0) revert InvalidConfig();
        TokenConfig memory cfg = tokens[token];
        if (!cfg.exists) revert TokenNotRegistered();
        if (!cfg.enabled) revert TokenDisabled();
        _requireDeveloperFxQualified(token);

        tokenBurned = quoteTokenIn(token, gbAmount);
        _burnDeveloperToken(user, token, tokenBurned);
        gbToken.mintPaid(settlement, gbAmount);
        emit DeveloperBurnedForGb(user, token, settlement, tokenBurned, gbAmount);
    }

    /**
     * @notice PayByUse: round burn up to whole tokens, mint **total** GB (≥ usage) to Settlement.
     * @return tokenBurned Whole-token wei burned from `user`.
     * @return gbMinted Total GB minted (miner takes usage; surplus credited to ERC20 contract by Settlement).
     */
    function burnDeveloperWholeTokensMintGbToSettlement(address user, address token, uint256 gbAmount)
        external
        returns (uint256 tokenBurned, uint256 gbMinted)
    {
        if (msg.sender != settlement && !admins[msg.sender]) revert Unauthorized();
        if (user == address(0) || gbAmount == 0) revert InvalidConfig();
        TokenConfig memory cfg = tokens[token];
        if (!cfg.exists) revert TokenNotRegistered();
        if (!cfg.enabled) revert TokenDisabled();
        _requireDeveloperFxQualified(token);

        uint256 weiNeeded = quoteTokenIn(token, gbAmount);
        uint256 full = 10 ** uint256(cfg.tokenDecimals);
        uint256 wholes = (weiNeeded + full - 1) / full;
        if (wholes == 0) revert InvalidConfig();
        tokenBurned = wholes * full;
        gbMinted = quoteGbOut(token, tokenBurned);
        if (gbMinted < gbAmount) revert InvalidConfig();

        _burnDeveloperToken(user, token, tokenBurned);
        gbToken.mintPaid(settlement, gbMinted);
        emit DeveloperBurnedForGb(user, token, settlement, tokenBurned, gbMinted);
    }

    /**
     * @notice Reverse: burn paid GB from `user`, mint developer Canonical via **treasury** (not Registry mint).
     * @dev Requires `treasury` wired; Canonical must grant TREASURY_ROLE to treasury only + BURN_ROLE to this registry.
     */
    function burnGbMintDeveloper(address user, address token, uint256 gbAmount) external returns (uint256 tokenMinted) {
        if (msg.sender != user && !admins[msg.sender]) revert Unauthorized();
        if (user == address(0) || gbAmount == 0) revert InvalidConfig();
        if (treasury == address(0)) revert InvalidConfig();
        TokenConfig memory cfg = tokens[token];
        if (!cfg.exists) revert TokenNotRegistered();
        if (!cfg.enabled) revert TokenDisabled();
        _requireDeveloperFxQualified(token);

        uint256 full = 10 ** uint256(cfg.tokenDecimals);
        tokenMinted = (gbAmount * full) / cfg.gbPerFullToken;
        if (tokenMinted == 0) revert InvalidConfig();

        gbToken.burnPaidFrom(user, gbAmount);
        ITreasuryMintDeveloperFx(treasury).mintDeveloperFxFromRegistry(token, user, tokenMinted);
        emit GbBurnedForDeveloper(user, token, gbAmount, tokenMinted);
    }

    function _burnDeveloperToken(address user, address token, uint256 amount) internal {
        try IERC20BurnFrom(token).burnFrom(user, amount) {
            return;
        } catch {
            bool ok = IERC20Meta(token).transferFrom(user, address(this), amount);
            if (!ok) revert TransferFailed();
        }
    }
}
