// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";

/**
 * @title DepinGbSettlement1155
 * @notice CoNET-only (224422) UUPS ERC-1155 DePIN GB settlement.
 *
 * Developer APP monetization (treasury FX ERC20 + 1:1 NFT#):
 *  1. PayByUse (kind 2): user holds NFT#; miner burns **user** FX tokens (whole-token ceil),
 *     mints GB at FX rate (> CoNET baseline); miner takes usage GB; surplus GB → ERC20 contract
 *     (owner rescues via Canonical `rescueERC20`).
 *  2. Subscription (kind 3): user holds timed NFT#; miner burns **issuer** FX prepaid for exact
 *     usage GB; customer not charged.
 *  3. Dual (kind 4): same NFT#; settler sets `SettleItem.billingMode` to 2 or 3.
 *  4. Settlement (kind 1): debit issuer GBToken via consumeGb (no FX ERC20).
 *
 * FX pass registration (**only Treasury**): `registerFxPassFromTreasury`.
 * Admin `configurePass` is SETTLEMENT-kind only. Developer FX tokens must keep
 * CNET stake ≥ treasury floor or Settlement / treasury refuse the app.
 * Canonical address = ERC1967 proxy; upgradeable in place; CoNET only.
 *
 * Miner one-shot read: `getUserSettlementAssets(user)` → GB pools + all held Settlement NFT# /
 * FX balances so the settler can choose passTokenId + billingMode.
 */

interface IGBTokenSettlement {
    function consumeGb(address user, uint256 amount) external returns (uint256 freeBurned, uint256 paidBurned);

    function mintPaid(address to, uint256 amount) external;

    function balanceOfAll(address account) external view returns (uint256 total, uint256 free, uint256 paid);
}

interface IValidatorDepositRedeemSettlement {
    function guardianIdBeneficiary(uint256 nodeId) external view returns (address);
}

interface IDeveloperTokenFxRegistry {
    function burnDeveloperMintGbToSettlement(address user, address erc20, uint256 gbAmount)
        external
        returns (uint256 tokenBurned);

    function burnDeveloperWholeTokensMintGbToSettlement(address user, address erc20, uint256 gbAmount)
        external
        returns (uint256 tokenBurned, uint256 gbMinted);

    function tokens(address token)
        external
        view
        returns (bool exists, bool enabled, uint8 tokenDecimals, uint256 gbPerFullToken, address developer);
}

interface IDeveloperTokenStakeSettlement {
    function isTreasuryQualified() external view returns (bool);

    function refundMinerGas(address miner) external returns (uint256 paid);
}

contract DepinGbSettlement1155 is Initializable, ERC1155Upgradeable, UUPSUpgradeable {
    // -------------------------------------------------------------------------
    // Kinds
    // -------------------------------------------------------------------------
    uint8 public constant PASS_KIND_NONE = 0;
    /// @notice Timed pass: debit issuer GBToken via consumeGb (customer not charged).
    uint8 public constant PASS_KIND_SETTLEMENT = 1;
    /// @notice PayByUse: burn **user** FX ERC20 (whole tokens); surplus GB → ERC20 contract.
    uint8 public constant PASS_KIND_PAY_BY_USE = 2;
    /// @notice Subscription: debit **issuer** FX ERC20 prepaid for exact usage.
    uint8 public constant PASS_KIND_SUBSCRIPTION = 3;
    /// @notice Both PayByUse + Subscription on the same NFT#; settler sets billingMode.
    uint8 public constant PASS_KIND_FX_DUAL = 4;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------
    IGBTokenSettlement public gbToken;
    IValidatorDepositRedeemSettlement public validatorDepositRedeem;
    IDeveloperTokenFxRegistry public developerTokenFxRegistry;

    mapping(address => bool) public admins;

    /// @dev Self-bonded CNET for settler admission (distinct from VDR protocol 32-CNET stake).
    mapping(address => uint256) public bondOf;
    uint256 public minBondWei;
    uint256 public unbondDelay;
    mapping(address => uint256) public pendingUnbondAmount;
    mapping(address => uint64) public pendingUnbondReadyAt;

    struct PassConfig {
        address developer;
        uint64 expiresAt;
        uint8 kind;
        bool exists;
        address payByUseErc20;
    }

    mapping(uint256 => PassConfig) public passConfig;

    /// @dev Cumulative GB consumed / paid reminted (ledger).
    mapping(address => uint256) public payerGbBurnedTotal;
    mapping(address => uint256) public creditGbMintedTotal;
    mapping(uint256 => uint256) public guardianNodeGbBurnedTotal;

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /// @dev 1:1 ERC20 ↔ NFT# (append-only upgrade storage).
    mapping(address => uint256) public erc20ToPassId;
    mapping(uint256 => address) public passIdToErc20;

    /// @dev Enumerated configured pass tokenIds for miner asset scans (append-only).
    uint256[] private _configuredPassIds;
    /// @dev 1-based index into `_configuredPassIds` (0 = not tracked).
    mapping(uint256 => uint256) private _configuredPassIdIndex;

    /// @dev TreasuryBridgeV3 — authorized registrar for FX developer passes.
    address public treasury;
    /// @dev DeveloperFxIssuer — may register FX passes (same gate as treasury).
    address public fxIssuer;

    uint256[34] private __gap;

    // -------------------------------------------------------------------------
    // Events / errors
    // -------------------------------------------------------------------------
    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event GbTokenSet(address indexed gbToken);
    event ValidatorDepositRedeemSet(address indexed vdr);
    event DeveloperTokenFxRegistrySet(address indexed registry);
    event TreasurySet(address indexed treasury);
    event FxIssuerSet(address indexed fxIssuer);
    event MinBondWeiSet(uint256 minBondWei);
    event UnbondDelaySet(uint256 unbondDelay);
    event BondDeposited(address indexed account, uint256 amount, uint256 bondOf);
    event UnbondRequested(address indexed account, uint256 amount, uint64 readyAt);
    event UnbondCompleted(address indexed account, uint256 amount);
    event PassConfigured(
        uint256 indexed tokenId, address indexed developer, uint8 kind, uint64 expiresAt, address payByUseErc20
    );
    event DeveloperFxPassLinked(address indexed erc20, uint256 indexed passTokenId);
    event ConfiguredPassTracked(uint256 indexed passTokenId);
    event PassMinted(uint256 indexed tokenId, address indexed to, uint256 amount);
    event Settled(
        address indexed settler,
        address indexed user,
        address indexed payer,
        address creditTo,
        uint256 guardianNodeId,
        uint256 amount,
        uint256 freeBurned,
        uint256 paidBurned,
        uint256 passTokenId,
        bytes32 reasonHash
    );
    event SubscriptionSettled(
        address indexed user,
        address indexed issuer,
        address indexed erc20,
        uint256 passTokenId,
        uint256 gbAmount,
        uint256 tokenBurned,
        address creditTo
    );
    event PayByUseSettled(
        address indexed user,
        address indexed erc20,
        uint256 passTokenId,
        uint256 usageGb,
        uint256 gbMinted,
        uint256 surplusGb,
        uint256 tokenBurned,
        address creditTo,
        address surplusTo
    );

    error ZeroAddress();
    error Unauthorized();
    error InvalidAmount();
    error InvalidConfig();
    error NotSettler();
    error NotAdminCredit();
    error InsufficientBond();
    error UnbondNotReady();
    error NoPendingUnbond();
    error PassNotFound();
    error PassExpired();
    error PassNotHeld();
    error PassKindMismatch();
    error ConsumeFailed();
    error PayByUseNotReady();
    error Reentrancy();
    error TransferFailed();
    error Erc20AlreadyLinked();
    error PassAlreadyLinked();
    error BillingModeRequired();
    error DeveloperTokenUnqualified();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------
    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlySettler() {
        if (!isSettler(msg.sender)) revert NotSettler();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Accept native CNET (bond deposits / top-ups).
    receive() external payable {
        _depositBond(msg.sender, msg.value);
    }

    function initialize(
        address initialAdmin,
        address gbToken_,
        address validatorDepositRedeem_,
        string memory uri_,
        uint256 minBondWei_,
        uint256 unbondDelay_
    ) external initializer {
        if (initialAdmin == address(0) || gbToken_ == address(0)) revert ZeroAddress();
        __ERC1155_init(uri_);
        __UUPSUpgradeable_init();
        _status = _NOT_ENTERED;
        admins[initialAdmin] = true;
        emit AdminAdded(initialAdmin);
        gbToken = IGBTokenSettlement(gbToken_);
        emit GbTokenSet(gbToken_);
        if (validatorDepositRedeem_ != address(0)) {
            validatorDepositRedeem = IValidatorDepositRedeemSettlement(validatorDepositRedeem_);
            emit ValidatorDepositRedeemSet(validatorDepositRedeem_);
        }
        minBondWei = minBondWei_;
        emit MinBondWeiSet(minBondWei_);
        unbondDelay = unbondDelay_;
        emit UnbondDelaySet(unbondDelay_);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    // -------------------------------------------------------------------------
    // Admin config
    // -------------------------------------------------------------------------
    function addAdmin(address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        admins[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        admins[account] = false;
        emit AdminRemoved(account);
    }

    function setGbToken(address gbToken_) external onlyAdmin {
        if (gbToken_ == address(0)) revert ZeroAddress();
        gbToken = IGBTokenSettlement(gbToken_);
        emit GbTokenSet(gbToken_);
    }

    function setValidatorDepositRedeem(address vdr) external onlyAdmin {
        validatorDepositRedeem = IValidatorDepositRedeemSettlement(vdr);
        emit ValidatorDepositRedeemSet(vdr);
    }

    function setDeveloperTokenFxRegistry(address registry) external onlyAdmin {
        developerTokenFxRegistry = IDeveloperTokenFxRegistry(registry);
        emit DeveloperTokenFxRegistrySet(registry);
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

    function setMinBondWei(uint256 minBondWei_) external onlyAdmin {
        minBondWei = minBondWei_;
        emit MinBondWeiSet(minBondWei_);
    }

    function setUnbondDelay(uint256 unbondDelay_) external onlyAdmin {
        unbondDelay = unbondDelay_;
        emit UnbondDelaySet(unbondDelay_);
    }

    function setURI(string memory newuri) external onlyAdmin {
        _setURI(newuri);
    }

    // -------------------------------------------------------------------------
    // Settler bond (CNET)
    // -------------------------------------------------------------------------
    function isSettler(address account) public view returns (bool) {
        return bondOf[account] >= minBondWei && minBondWei > 0;
    }

    function bondDeposit() external payable nonReentrant {
        _depositBond(msg.sender, msg.value);
    }

    function _depositBond(address account, uint256 amount) internal {
        if (amount == 0) revert InvalidAmount();
        bondOf[account] += amount;
        emit BondDeposited(account, amount, bondOf[account]);
    }

    function requestUnbond(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (bondOf[msg.sender] < amount) revert InsufficientBond();
        bondOf[msg.sender] -= amount;
        pendingUnbondAmount[msg.sender] += amount;
        uint64 readyAt = uint64(block.timestamp + unbondDelay);
        pendingUnbondReadyAt[msg.sender] = readyAt;
        emit UnbondRequested(msg.sender, amount, readyAt);
    }

    function completeUnbond() external nonReentrant {
        uint256 amount = pendingUnbondAmount[msg.sender];
        if (amount == 0) revert NoPendingUnbond();
        if (block.timestamp < pendingUnbondReadyAt[msg.sender]) revert UnbondNotReady();
        pendingUnbondAmount[msg.sender] = 0;
        pendingUnbondReadyAt[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit UnbondCompleted(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Pass config + mint
    // -------------------------------------------------------------------------
    function _isFxKind(uint8 kind) internal pure returns (bool) {
        return kind == PASS_KIND_PAY_BY_USE || kind == PASS_KIND_SUBSCRIPTION || kind == PASS_KIND_FX_DUAL;
    }

    function _linkErc20Pass(uint256 tokenId, address erc20) internal {
        uint256 existingId = erc20ToPassId[erc20];
        if (existingId != 0 && existingId != tokenId) revert Erc20AlreadyLinked();
        address existingErc20 = passIdToErc20[tokenId];
        if (existingErc20 != address(0) && existingErc20 != erc20) revert PassAlreadyLinked();
        erc20ToPassId[erc20] = tokenId;
        passIdToErc20[tokenId] = erc20;
        emit DeveloperFxPassLinked(erc20, tokenId);
    }

    function _trackConfiguredPassId(uint256 tokenId) internal {
        if (_configuredPassIdIndex[tokenId] != 0) return;
        _configuredPassIds.push(tokenId);
        _configuredPassIdIndex[tokenId] = _configuredPassIds.length; // 1-based
        emit ConfiguredPassTracked(tokenId);
    }

    /// @notice Admin seed / repair for pass ids configured before enumeration existed.
    function seedConfiguredPassIds(uint256[] calldata tokenIds) external onlyAdmin {
        uint256 n = tokenIds.length;
        for (uint256 i = 0; i < n;) {
            uint256 id = tokenIds[i];
            if (passConfig[id].exists) {
                _trackConfiguredPassId(id);
            }
            unchecked {
                ++i;
            }
        }
    }

    function configuredPassCount() external view returns (uint256) {
        return _configuredPassIds.length;
    }

    function configuredPassIdAt(uint256 index) external view returns (uint256) {
        return _configuredPassIds[index];
    }

    function configuredPassIds() external view returns (uint256[] memory) {
        return _configuredPassIds;
    }

    /**
     * @notice Treasury-only: create/update FX developer pass with 1:1 ERC20 link.
     * @dev Called from TreasuryBridgeV3.issueDeveloperFxAndRegister — rejects registry/admin.
     */
    function registerFxPassFromTreasury(
        uint256 tokenId,
        address developer,
        uint8 kind,
        uint64 expiresAt,
        address erc20
    ) external {
        if (msg.sender != treasury && msg.sender != fxIssuer) revert Unauthorized();
        if (msg.sender == address(0)) revert Unauthorized();
        _registerFxPass(tokenId, developer, kind, expiresAt, erc20);
    }

    function _registerFxPass(
        uint256 tokenId,
        address developer,
        uint8 kind,
        uint64 expiresAt,
        address erc20
    ) internal {
        if (developer == address(0) || erc20 == address(0)) revert ZeroAddress();
        if (!_isFxKind(kind)) revert InvalidConfig();
        if (expiresAt == 0) revert InvalidConfig();
        _linkErc20Pass(tokenId, erc20);
        passConfig[tokenId] = PassConfig({
            developer: developer,
            expiresAt: expiresAt,
            kind: kind,
            exists: true,
            payByUseErc20: erc20
        });
        _trackConfiguredPassId(tokenId);
        emit PassConfigured(tokenId, developer, kind, expiresAt, erc20);
    }

    /**
     * @notice Admin may only configure SETTLEMENT-kind (issuer GB debit, no FX ERC20).
     * @dev Developer FX passes (kinds 2/3/4) must use Treasury.issueDeveloperFxAndRegister.
     */
    function configurePass(
        uint256 tokenId,
        address developer,
        uint8 kind,
        uint64 expiresAt,
        address payByUseErc20
    ) external onlyAdmin {
        if (developer == address(0)) revert ZeroAddress();
        if (kind != PASS_KIND_SETTLEMENT) revert Unauthorized();
        if (expiresAt == 0) revert InvalidConfig();
        if (payByUseErc20 != address(0)) revert InvalidConfig();

        passConfig[tokenId] = PassConfig({
            developer: developer,
            expiresAt: expiresAt,
            kind: kind,
            exists: true,
            payByUseErc20: address(0)
        });
        _trackConfiguredPassId(tokenId);
        emit PassConfigured(tokenId, developer, kind, expiresAt, address(0));
    }

    /// @notice Mint subscription / settlement / PayByUse pass balances. Caller = admin or developer.
    function mintPass(address to, uint256 tokenId, uint256 amount) external {
        if (to == address(0) || amount == 0) revert InvalidAmount();
        PassConfig memory cfg = passConfig[tokenId];
        if (!cfg.exists) revert PassNotFound();
        if (msg.sender != cfg.developer && !admins[msg.sender]) revert Unauthorized();
        _mint(to, tokenId, amount, "");
        emit PassMinted(tokenId, to, amount);
    }

    function isPassValid(address holder, uint256 tokenId) public view returns (bool) {
        PassConfig memory cfg = passConfig[tokenId];
        if (!cfg.exists) return false;
        if (block.timestamp >= cfg.expiresAt) return false;
        return balanceOf(holder, tokenId) > 0;
    }

    /**
     * @notice Resolve who pays for `user` when holding `passTokenId` (billingMode ignored for view).
     * @dev PayByUse → user; Subscription / Settlement → developer.
     */
    function resolvePayer(address user, uint256 passTokenId) public view returns (address payer, uint8 kind) {
        return resolvePayerWithMode(user, passTokenId, 0);
    }

    function resolvePayerWithMode(address user, uint256 passTokenId, uint8 billingMode)
        public
        view
        returns (address payer, uint8 kind)
    {
        if (user == address(0)) revert ZeroAddress();
        if (passTokenId == 0) return (user, PASS_KIND_NONE);
        PassConfig memory cfg = passConfig[passTokenId];
        if (!cfg.exists) revert PassNotFound();
        if (block.timestamp >= cfg.expiresAt) revert PassExpired();
        if (balanceOf(user, passTokenId) == 0) revert PassNotHeld();

        uint8 effective = _effectiveBillingKind(cfg.kind, billingMode);
        if (effective == PASS_KIND_PAY_BY_USE) {
            return (user, PASS_KIND_PAY_BY_USE);
        }
        if (effective == PASS_KIND_SETTLEMENT || effective == PASS_KIND_SUBSCRIPTION) {
            return (cfg.developer, effective);
        }
        return (user, effective);
    }

    function _effectiveBillingKind(uint8 passKind, uint8 billingMode) internal pure returns (uint8) {
        if (passKind == PASS_KIND_FX_DUAL) {
            if (billingMode != PASS_KIND_PAY_BY_USE && billingMode != PASS_KIND_SUBSCRIPTION) {
                revert BillingModeRequired();
            }
            return billingMode;
        }
        if (billingMode != 0 && billingMode != passKind) {
            // Allow explicit match; ignore if 0.
            if (passKind == PASS_KIND_PAY_BY_USE || passKind == PASS_KIND_SUBSCRIPTION) {
                if (billingMode == PASS_KIND_PAY_BY_USE || billingMode == PASS_KIND_SUBSCRIPTION) {
                    revert PassKindMismatch();
                }
            }
        }
        return passKind;
    }

    // -------------------------------------------------------------------------
    // Miner one-shot asset query (settle routing)
    // -------------------------------------------------------------------------

    /// @notice One Settlement NFT# holding + FX context for settle routing.
    struct UserPassAsset {
        uint256 passTokenId;
        uint256 balance;
        address developer;
        uint64 expiresAt;
        uint8 kind;
        /// @dev balance > 0 && exists && block.timestamp < expiresAt
        bool active;
        address fxErc20;
        /// @dev User FX ERC20 balance (PayByUse burn source).
        uint256 userFxBalance;
        /// @dev Issuer FX ERC20 balance (Subscription prepaid).
        uint256 issuerFxBalance;
        uint256 gbPerFullToken;
        bool fxEnabled;
    }

    /// @notice Aggregated Settlement view for one address (GB + all held passes).
    struct UserSettlementAssets {
        address user;
        uint256 gbTotal;
        uint256 gbFree;
        uint256 gbPaid;
        /// @dev Ledger: cumulative GB attributed as burned for this address as payer.
        uint256 payerGbBurnedTotal;
        UserPassAsset[] passes;
    }

    /**
     * @notice Miner one-shot: user GB pools + every configured Settlement NFT# this user holds.
     * @dev Scans `_configuredPassIds` (seed legacy ids via `seedConfiguredPassIds`). Only returns
     *      passes with `balance > 0`. Use `getUserSettlementAssetsByIds` when APP already marks ids.
     */
    function getUserSettlementAssets(address user) external view returns (UserSettlementAssets memory out) {
        if (user == address(0)) revert ZeroAddress();
        return _buildUserSettlementAssets(user, _configuredPassIds, true);
    }

    /**
     * @notice Same as `getUserSettlementAssets` but only for explicit `passIds` (APP-marked / known).
     * @param onlyHeld If true, skip passIds with zero balance; if false, include zero-balance rows.
     */
    function getUserSettlementAssetsByIds(address user, uint256[] calldata passIds, bool onlyHeld)
        external
        view
        returns (UserSettlementAssets memory out)
    {
        if (user == address(0)) revert ZeroAddress();
        uint256 n = passIds.length;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            ids[i] = passIds[i];
            unchecked {
                ++i;
            }
        }
        return _buildUserSettlementAssets(user, ids, onlyHeld);
    }

    /**
     * @notice Suggest settle route for `amountGb` given user's current Settlement assets.
     * @dev Preference: Subscription (issuer FX covers) → PayByUse (user whole-token covers) →
     *      Settlement kind (issuer GB) → user GB (`passTokenId=0`). Dual NFT uses billingMode 3 then 2.
     * @return passTokenId 0 = debit user GBToken
     * @return billingMode 0 / 2 / 3 as for SettleItem
     * @return kind Effective pass kind (or NONE)
     * @return payer Who will be burned (user or issuer)
     * @return feasible True if a covered route exists
     */
    function suggestSettleRoute(address user, uint256 amountGb)
        external
        view
        returns (uint256 passTokenId, uint8 billingMode, uint8 kind, address payer, bool feasible)
    {
        if (user == address(0) || amountGb == 0) revert InvalidAmount();
        UserSettlementAssets memory snap = _buildUserSettlementAssets(user, _configuredPassIds, true);

        // 1) Subscription / Dual with issuer FX prepaid covering exact usage.
        for (uint256 i = 0; i < snap.passes.length;) {
            UserPassAsset memory p = snap.passes[i];
            if (!p.active || !p.fxEnabled || p.gbPerFullToken == 0 || p.fxErc20 == address(0)) {
                unchecked {
                    ++i;
                }
                continue;
            }
            if (p.kind == PASS_KIND_SUBSCRIPTION || p.kind == PASS_KIND_FX_DUAL) {
                uint8 dec = _fxDecimals(p.fxErc20);
                uint256 need = _quoteTokenInView(amountGb, p.gbPerFullToken, dec);
                if (p.issuerFxBalance >= need) {
                    uint8 mode = p.kind == PASS_KIND_FX_DUAL ? PASS_KIND_SUBSCRIPTION : uint8(0);
                    return (p.passTokenId, mode, PASS_KIND_SUBSCRIPTION, p.developer, true);
                }
            }
            unchecked {
                ++i;
            }
        }

        // 2) PayByUse / Dual with user FX covering whole-token ceil.
        for (uint256 i = 0; i < snap.passes.length;) {
            UserPassAsset memory p = snap.passes[i];
            if (!p.active || !p.fxEnabled || p.gbPerFullToken == 0 || p.fxErc20 == address(0)) {
                unchecked {
                    ++i;
                }
                continue;
            }
            if (p.kind == PASS_KIND_PAY_BY_USE || p.kind == PASS_KIND_FX_DUAL) {
                uint8 dec = _fxDecimals(p.fxErc20);
                uint256 needWei = _quoteTokenInView(amountGb, p.gbPerFullToken, dec);
                uint256 full = 10 ** uint256(dec);
                uint256 wholes = (needWei + full - 1) / full;
                uint256 burnWei = wholes * full;
                if (p.userFxBalance >= burnWei) {
                    uint8 mode = p.kind == PASS_KIND_FX_DUAL ? PASS_KIND_PAY_BY_USE : uint8(0);
                    return (p.passTokenId, mode, PASS_KIND_PAY_BY_USE, user, true);
                }
            }
            unchecked {
                ++i;
            }
        }

        // 3) Settlement-kind: issuer GBToken.
        for (uint256 i = 0; i < snap.passes.length;) {
            UserPassAsset memory p = snap.passes[i];
            if (p.active && p.kind == PASS_KIND_SETTLEMENT) {
                (uint256 issuerTotal,,) = gbToken.balanceOfAll(p.developer);
                if (issuerTotal >= amountGb) {
                    return (p.passTokenId, 0, PASS_KIND_SETTLEMENT, p.developer, true);
                }
            }
            unchecked {
                ++i;
            }
        }

        // 4) User pays GB directly.
        if (snap.gbTotal >= amountGb) {
            return (0, 0, PASS_KIND_NONE, user, true);
        }
        return (0, 0, PASS_KIND_NONE, user, false);
    }

    function _fxDecimals(address erc20) internal view returns (uint8) {
        if (address(developerTokenFxRegistry) == address(0)) return 18;
        (bool exists,, uint8 dec,,) = developerTokenFxRegistry.tokens(erc20);
        if (!exists) return 18;
        return dec;
    }

    function _quoteTokenInView(uint256 amountGb, uint256 gbPerFullToken, uint8 tokenDecimals)
        internal
        pure
        returns (uint256)
    {
        if (amountGb == 0 || gbPerFullToken == 0) return 0;
        uint256 full = 10 ** uint256(tokenDecimals);
        return (amountGb * full + gbPerFullToken - 1) / gbPerFullToken;
    }

    function _buildUserSettlementAssets(address user, uint256[] memory passIds, bool onlyHeld)
        internal
        view
        returns (UserSettlementAssets memory out)
    {
        out.user = user;
        (out.gbTotal, out.gbFree, out.gbPaid) = gbToken.balanceOfAll(user);
        out.payerGbBurnedTotal = payerGbBurnedTotal[user];

        uint256 n = passIds.length;
        uint256 held = 0;
        UserPassAsset[] memory tmp = new UserPassAsset[](n);
        for (uint256 i = 0; i < n;) {
            uint256 id = passIds[i];
            PassConfig memory cfg = passConfig[id];
            if (!cfg.exists) {
                unchecked {
                    ++i;
                }
                continue;
            }
            uint256 bal = balanceOf(user, id);
            if (onlyHeld && bal == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            UserPassAsset memory row;
            row.passTokenId = id;
            row.balance = bal;
            row.developer = cfg.developer;
            row.expiresAt = cfg.expiresAt;
            row.kind = cfg.kind;
            row.active = bal > 0 && block.timestamp < cfg.expiresAt;
            row.fxErc20 = cfg.payByUseErc20;
            if (cfg.payByUseErc20 != address(0)) {
                row.userFxBalance = IERC20Balance(cfg.payByUseErc20).balanceOf(user);
                row.issuerFxBalance = IERC20Balance(cfg.payByUseErc20).balanceOf(cfg.developer);
                if (address(developerTokenFxRegistry) != address(0)) {
                    (bool exists, bool enabled,, uint256 rate,) = developerTokenFxRegistry.tokens(cfg.payByUseErc20);
                    if (exists) {
                        row.fxEnabled = enabled;
                        row.gbPerFullToken = rate;
                    }
                }
            }
            tmp[held] = row;
            unchecked {
                ++held;
                ++i;
            }
        }

        out.passes = new UserPassAsset[](held);
        for (uint256 j = 0; j < held;) {
            out.passes[j] = tmp[j];
            unchecked {
                ++j;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Batch settle
    // -------------------------------------------------------------------------
    struct SettleItem {
        address user;
        uint256 amountGb;
        /// @dev Credit recipient: must be settler/admin when non-zero (mailbox forward fee, etc.).
        address toAdmin;
        /// @dev If toAdmin == 0 and guardianNodeId > 0, credit VDR redeem beneficiary (paidBurned only).
        uint256 guardianNodeId;
        /// @dev 0 = user pays GB; else NFT# for Settlement / PayByUse / Subscription / Dual.
        uint256 passTokenId;
        bytes32 reasonHash;
        /// @dev 0 = use pass kind; for FX_DUAL must be 2 (PayByUse) or 3 (Subscription).
        uint8 billingMode;
    }

    /**
     * @notice All-or-nothing batch settle.
     * @dev One miner gas refund per call from the first FX token touched (treasury-configured wei).
     */
    function batchSettle(SettleItem[] calldata items) external onlySettler nonReentrant {
        uint256 n = items.length;
        if (n == 0) revert InvalidAmount();

        address gasRefundErc20;
        for (uint256 i = 0; i < n;) {
            address fx = _settleOne(items[i]);
            if (gasRefundErc20 == address(0) && fx != address(0)) {
                gasRefundErc20 = fx;
            }
            unchecked {
                ++i;
            }
        }
        if (gasRefundErc20 != address(0)) {
            // Reverts whole batch if stake cannot cover treasury-configured miner gas refund.
            IDeveloperTokenStakeSettlement(gasRefundErc20).refundMinerGas(msg.sender);
        }
    }

    /// @return fxErc20 Developer FX token used (for miner gas refund), or zero.
    function _settleOne(SettleItem calldata item) internal returns (address fxErc20) {
        if (item.user == address(0) || item.amountGb == 0) revert InvalidAmount();

        if (item.passTokenId == 0) {
            _settleUserGb(item);
            return address(0);
        }

        PassConfig memory cfg = passConfig[item.passTokenId];
        if (!cfg.exists) revert PassNotFound();
        if (block.timestamp >= cfg.expiresAt) revert PassExpired();
        if (balanceOf(item.user, item.passTokenId) == 0) revert PassNotHeld();

        uint8 effective = _effectiveBillingKind(cfg.kind, item.billingMode);

        if (effective == PASS_KIND_PAY_BY_USE) {
            _requireFxTokenQualified(cfg.payByUseErc20);
            _settlePayByUse(item, cfg);
            return cfg.payByUseErc20;
        }
        if (effective == PASS_KIND_SUBSCRIPTION) {
            _requireFxTokenQualified(cfg.payByUseErc20);
            _settleSubscription(item, cfg);
            return cfg.payByUseErc20;
        }
        if (effective == PASS_KIND_SETTLEMENT) {
            _settleIssuerGb(item, cfg);
            return address(0);
        }
        revert PassKindMismatch();
    }

    function _requireFxTokenQualified(address erc20) internal view {
        if (erc20 == address(0)) revert InvalidConfig();
        if (!IDeveloperTokenStakeSettlement(erc20).isTreasuryQualified()) {
            revert DeveloperTokenUnqualified();
        }
    }

    function _settleUserGb(SettleItem calldata item) internal {
        address creditTo = _resolveCreditTo(item);
        (uint256 freeBurned, uint256 paidBurned) = gbToken.consumeGb(item.user, item.amountGb);
        if (freeBurned + paidBurned != item.amountGb) revert ConsumeFailed();

        payerGbBurnedTotal[item.user] += item.amountGb;
        if (item.guardianNodeId != 0) {
            guardianNodeGbBurnedTotal[item.guardianNodeId] += item.amountGb;
        }

        if (paidBurned > 0 && creditTo != address(0)) {
            gbToken.mintPaid(creditTo, paidBurned);
            creditGbMintedTotal[creditTo] += paidBurned;
        }

        emit Settled(
            msg.sender,
            item.user,
            item.user,
            creditTo,
            item.guardianNodeId,
            item.amountGb,
            freeBurned,
            paidBurned,
            0,
            item.reasonHash
        );
    }

    function _settleIssuerGb(SettleItem calldata item, PassConfig memory cfg) internal {
        address creditTo = _resolveCreditTo(item);
        (uint256 freeBurned, uint256 paidBurned) = gbToken.consumeGb(cfg.developer, item.amountGb);
        if (freeBurned + paidBurned != item.amountGb) revert ConsumeFailed();

        payerGbBurnedTotal[cfg.developer] += item.amountGb;
        if (item.guardianNodeId != 0) {
            guardianNodeGbBurnedTotal[item.guardianNodeId] += item.amountGb;
        }

        if (paidBurned > 0 && creditTo != address(0)) {
            gbToken.mintPaid(creditTo, paidBurned);
            creditGbMintedTotal[creditTo] += paidBurned;
        }

        emit Settled(
            msg.sender,
            item.user,
            cfg.developer,
            creditTo,
            item.guardianNodeId,
            item.amountGb,
            freeBurned,
            paidBurned,
            item.passTokenId,
            item.reasonHash
        );
    }

    function _resolveCreditTo(SettleItem calldata item) internal view returns (address creditTo) {
        if (item.toAdmin != address(0)) {
            if (!isSettler(item.toAdmin) && !admins[item.toAdmin]) revert NotAdminCredit();
            return item.toAdmin;
        }
        if (item.guardianNodeId != 0) {
            address vdr = address(validatorDepositRedeem);
            if (vdr == address(0)) revert InvalidConfig();
            address beneficiary = validatorDepositRedeem.guardianIdBeneficiary(item.guardianNodeId);
            if (beneficiary == address(0)) revert InvalidConfig();
            return beneficiary;
        }
        return address(0);
    }

    /**
     * @dev PayByUse: burn user FX (whole tokens) → mint total GB; miner gets usage; surplus → ERC20 contract.
     */
    function _settlePayByUse(SettleItem calldata item, PassConfig memory cfg) internal {
        if (address(developerTokenFxRegistry) == address(0)) revert PayByUseNotReady();
        if (cfg.payByUseErc20 == address(0)) revert InvalidConfig();

        address creditTo = _resolveCreditTo(item);
        if (creditTo == address(0)) revert InvalidConfig();

        (bool exists, bool enabled,, uint256 gbPerFullToken,) = developerTokenFxRegistry.tokens(cfg.payByUseErc20);
        if (!exists || !enabled || gbPerFullToken == 0) revert InvalidConfig();

        (uint256 tokenBurned, uint256 gbMinted) = developerTokenFxRegistry.burnDeveloperWholeTokensMintGbToSettlement(
            item.user, cfg.payByUseErc20, item.amountGb
        );
        if (gbMinted < item.amountGb) revert InvalidConfig();

        bool ok = IERC20Transfer(address(gbToken)).transfer(creditTo, item.amountGb);
        if (!ok) revert TransferFailed();

        uint256 surplus = gbMinted - item.amountGb;
        address surplusTo = cfg.payByUseErc20;
        if (surplus > 0) {
            ok = IERC20Transfer(address(gbToken)).transfer(surplusTo, surplus);
            if (!ok) revert TransferFailed();
            creditGbMintedTotal[surplusTo] += surplus;
        }

        creditGbMintedTotal[creditTo] += item.amountGb;
        payerGbBurnedTotal[item.user] += item.amountGb;
        if (item.guardianNodeId != 0) {
            guardianNodeGbBurnedTotal[item.guardianNodeId] += item.amountGb;
        }

        emit PayByUseSettled(
            item.user,
            cfg.payByUseErc20,
            item.passTokenId,
            item.amountGb,
            gbMinted,
            surplus,
            tokenBurned,
            creditTo,
            surplusTo
        );
        emit Settled(
            msg.sender,
            item.user,
            item.user,
            creditTo,
            item.guardianNodeId,
            item.amountGb,
            0,
            item.amountGb,
            item.passTokenId,
            item.reasonHash
        );
    }

    /**
     * @dev Subscription: debit issuer FX prepaid for exact usage; customer GB never consumed.
     */
    function _settleSubscription(SettleItem calldata item, PassConfig memory cfg) internal {
        if (address(developerTokenFxRegistry) == address(0)) revert PayByUseNotReady();
        if (cfg.payByUseErc20 == address(0)) revert InvalidConfig();

        address creditTo = _resolveCreditTo(item);
        if (creditTo == address(0)) revert InvalidConfig();

        (bool exists, bool enabled,, uint256 gbPerFullToken,) = developerTokenFxRegistry.tokens(cfg.payByUseErc20);
        if (!exists || !enabled || gbPerFullToken == 0) revert InvalidConfig();

        uint256 tokenBurned =
            developerTokenFxRegistry.burnDeveloperMintGbToSettlement(cfg.developer, cfg.payByUseErc20, item.amountGb);

        bool ok = IERC20Transfer(address(gbToken)).transfer(creditTo, item.amountGb);
        if (!ok) revert TransferFailed();

        creditGbMintedTotal[creditTo] += item.amountGb;
        payerGbBurnedTotal[cfg.developer] += item.amountGb;
        if (item.guardianNodeId != 0) {
            guardianNodeGbBurnedTotal[item.guardianNodeId] += item.amountGb;
        }

        emit SubscriptionSettled(
            item.user, cfg.developer, cfg.payByUseErc20, item.passTokenId, item.amountGb, tokenBurned, creditTo
        );
        emit Settled(
            msg.sender,
            item.user,
            cfg.developer,
            creditTo,
            item.guardianNodeId,
            item.amountGb,
            0,
            item.amountGb,
            item.passTokenId,
            item.reasonHash
        );
    }
}

interface IERC20Transfer {
    function transfer(address to, uint256 value) external returns (bool);
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}
