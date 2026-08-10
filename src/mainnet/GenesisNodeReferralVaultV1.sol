// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IERC20GenesisReferral {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Matches TreasuryBridgeV3 LockMint best-effort callback.
interface ITreasuryBridgeMintCallback {
    function onBridgeMint(
        bytes32 operationId,
        uint256 sourceChainId,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts
    ) external;
}

/**
 * @title GenesisNodeReferralVaultV1
 * @notice Admin → L0 → L1 registry for Genesis Node Offers.
 *         LockMint callback splits per node: L0 pool = 10% of 3880 (=388), Admin = 120+20% of 3880 (=896),
 *         Foundation = remainder (=2716). List price 4000 already includes OPEX 120. Purchase `referrer` may be:
 *         - active L1 → L1 takes `ratioBps` of the L0 pool; remainder to parent L0; admin = L0.parentAdmin
 *         - active L0 → full L0 pool to that L0 (no L1 cut); admin = L0.parentAdmin
 *         - Admin → no L0/L1 cut (L0 pool → foundation); admin bucket to that Admin
 *         - zero → no L0/L1 cut; admin bucket to `defaultAdminPayout`
 *         `testMode` sales use 1/1000 economics (3.88 + 0.12 = 4.00 USDC) with the same split ratios;
 *         owner may permanently disable testMode via `disableSaleTestMode`.
 */
contract GenesisNodeReferralVaultV1 is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ITreasuryBridgeMintCallback
{
    uint256 public constant BPS = 10_000;
    uint256 public constant NODE_PRICE_USDC6 = 3_880_000_000;
    uint256 public constant SERVER_FEE_USDC6 = 120_000_000;
    uint256 public constant TOTAL_PER_NODE_USDC6 = 4_000_000_000;
    /// @notice testMode seat: 1/1000 of production (3.88 + 0.12 = 4.00 USDC).
    uint256 public constant TEST_NODE_PRICE_USDC6 = 3_880_000;
    uint256 public constant TEST_SERVER_FEE_USDC6 = 120_000;
    uint256 public constant TEST_TOTAL_PER_NODE_USDC6 = 4_000_000;
    uint256 public constant L0_OF_NODE_BPS = 1_000;
    uint256 public constant ADMIN_OF_NODE_BPS = 2_000;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant EIP712_NAME_HASH = keccak256("GenesisNodeReferralVaultV1");
    bytes32 private constant EIP712_VERSION_HASH = keccak256("1");
    bytes32 public constant ISSUE_L0_REDEEM_TYPEHASH =
        keccak256("IssueL0RedeemCode(address admin,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 public constant CANCEL_L0_REDEEM_TYPEHASH =
        keccak256("CancelL0RedeemCode(address admin,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 public constant CLAIM_L0_REDEEM_TYPEHASH =
        keccak256("ClaimL0RedeemCode(address claimer,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 public constant ISSUE_L1_REDEEM_TYPEHASH = keccak256(
        "IssueL1RedeemCode(address l0,bytes32 redeemHash,uint256 ratioBps,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant CANCEL_L1_REDEEM_TYPEHASH =
        keccak256("CancelL1RedeemCode(address l0,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 public constant CLAIM_L1_REDEEM_TYPEHASH =
        keccak256("ClaimL1RedeemCode(address claimer,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 public constant SET_FOUNDATION_TYPEHASH =
        keccak256("SetFoundation(address admin,address foundation,uint256 nonce,uint256 deadline)");
    bytes32 public constant SET_DEFAULT_ADMIN_PAYOUT_TYPEHASH =
        keccak256("SetDefaultAdminPayout(address admin,address payout,uint256 nonce,uint256 deadline)");
    bytes32 public constant SET_L1_RATIO_TYPEHASH = keccak256(
        "SetL1Ratio(address l0,address l1,uint256 ratioBps,uint256 nonce,uint256 deadline)"
    );

    enum Role {
        None,
        L0,
        L1
    }

    /// @dev Append-only fields after `active` so existing L0 storage stays valid on upgrade.
    struct Member {
        Role role;
        address parentAdmin;
        bool active;
        address parentL0;
        uint256 ratioBps;
    }

    struct L0RedeemCode {
        address issuerAdmin;
        bool active;
        bool claimed;
        bool cancelled;
    }

    struct L1RedeemCode {
        address issuerL0;
        uint256 ratioBps;
        bool active;
        bool claimed;
        bool cancelled;
    }

    /// @dev Append `referrerL1` then `referrerAdmin` after `testMode` for upgrade-safe layout.
    struct Sale {
        address referrerL0;
        address buyer;
        uint256 qty;
        bool bound;
        bool settled;
        bool testMode;
        address referrerL1;
        /// @notice Set when bindSale referrer is an Admin (no L0/L1 cut).
        address referrerAdmin;
    }

    address public treasury;
    address public conetUsdc;
    address public foundation;
    address public defaultAdminPayout;
    address public bridgeBinder;

    mapping(address => bool) public admins;
    mapping(address => Member) public members;
    mapping(bytes32 => L0RedeemCode) public l0RedeemCodes;
    mapping(bytes32 => Sale) public sales;
    mapping(address => uint256) public redeemActionNonces;
    mapping(address => uint256) public claimNonces;
    mapping(address => uint256) public earnedUsdc6;

    address[] private _l0List;
    bytes32[] private _l0RedeemHashes;

    mapping(bytes32 => L1RedeemCode) public l1RedeemCodes;
    address[] private _l1List;
    bytes32[] private _l1RedeemHashes;

    /// @notice When true, `bindSale(..., testMode=true)` reverts. One-way: cannot re-enable after disable.
    bool public saleTestModePermanentlyDisabled;

    event AdminUpdated(address indexed account, bool enabled);
    event BridgeBinderUpdated(address indexed binder);
    event FoundationUpdated(address indexed foundation);
    event DefaultAdminPayoutUpdated(address indexed payout);
    event WiringUpdated(address indexed treasury, address indexed conetUsdc);
    event L0RedeemCodeIssued(bytes32 indexed redeemHash, address indexed admin);
    event L0RedeemCodeCancelled(bytes32 indexed redeemHash, address indexed admin);
    event L0RedeemCodeClaimed(bytes32 indexed redeemHash, address indexed l0, address indexed admin);
    event L1RedeemCodeIssued(bytes32 indexed redeemHash, address indexed l0, uint256 ratioBps);
    event L1RedeemCodeCancelled(bytes32 indexed redeemHash, address indexed l0);
    event L1RedeemCodeClaimed(bytes32 indexed redeemHash, address indexed l1, address indexed l0, uint256 ratioBps);
    event MemberRegistered(address indexed account, address indexed parentAdmin);
    event L1MemberRegistered(address indexed account, address indexed parentL0, uint256 ratioBps);
    event L1RatioUpdated(address indexed l1, address indexed l0, uint256 ratioBps);
    event SaleBound(
        bytes32 indexed operationId,
        address indexed referrerL0,
        address indexed buyer,
        uint256 qty,
        bool testMode,
        address referrerL1
    );
    event SaleSettled(
        bytes32 indexed operationId,
        address referrerL0,
        address referrerL1,
        address adminPayout,
        address foundationPayout,
        uint256 l0Amount,
        uint256 l1Amount,
        uint256 adminAmount,
        uint256 foundationAmount
    );
    event SaleUnboundSkipped(bytes32 indexed operationId, uint256 receivedAmount);
    event SaleAmountMismatch(bytes32 indexed operationId, uint256 expected, uint256 actual);
    event RescuedERC20(address indexed token, address indexed to, uint256 amount);
    event SaleTestModeDisabled();

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error AlreadyRegistered();
    error CodeUnavailable();
    error InvalidCode();
    error InvalidSignature();
    error SignatureExpired();
    error NonceUsed();
    error SaleAlreadyBound();
    error SaleAlreadySettled();
    error NotL0();
    error NotL1();
    error InvalidReferrer();
    error TransferFailed();
    error SaleTestModeNotAllowed();
    error SaleTestModeAlreadyDisabled();

    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyL0() {
        if (!isActiveL0(msg.sender)) revert NotL0();
        _;
    }

    modifier onlyBridgeBinder() {
        if (msg.sender != bridgeBinder) revert Unauthorized();
        _;
    }

    function initialize(
        address owner_,
        address treasury_,
        address conetUsdc_,
        address foundation_,
        address defaultAdminPayout_,
        address bridgeBinder_
    ) external initializer {
        if (
            owner_ == address(0) || treasury_ == address(0) || conetUsdc_ == address(0)
                || foundation_ == address(0) || defaultAdminPayout_ == address(0)
                || bridgeBinder_ == address(0)
        ) revert InvalidAddress();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        treasury = treasury_;
        conetUsdc = conetUsdc_;
        foundation = foundation_;
        defaultAdminPayout = defaultAdminPayout_;
        bridgeBinder = bridgeBinder_;
        admins[owner_] = true;
        emit AdminUpdated(owner_, true);
        emit WiringUpdated(treasury_, conetUsdc_);
        emit FoundationUpdated(foundation_);
        emit DefaultAdminPayoutUpdated(defaultAdminPayout_);
        emit BridgeBinderUpdated(bridgeBinder_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, EIP712_NAME_HASH, EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function setAdmin(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        admins[account] = enabled;
        emit AdminUpdated(account, enabled);
    }

    function setBridgeBinder(address binder) external onlyOwner {
        if (binder == address(0)) revert InvalidAddress();
        bridgeBinder = binder;
        emit BridgeBinderUpdated(binder);
    }

    /// @notice Permanently disallow `bindSale(..., testMode=true)`. Irreversible.
    function disableSaleTestMode() external onlyOwner {
        if (saleTestModePermanentlyDisabled) revert SaleTestModeAlreadyDisabled();
        saleTestModePermanentlyDisabled = true;
        emit SaleTestModeDisabled();
    }

    function setFoundation(address foundation_) external onlyAdmin {
        _setFoundation(foundation_);
    }

    function setFoundationFor(
        address admin,
        address foundation_,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyAdminAction(
            admin,
            keccak256(abi.encode(SET_FOUNDATION_TYPEHASH, admin, foundation_, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!admins[admin]) revert Unauthorized();
        _setFoundation(foundation_);
    }

    function _setFoundation(address foundation_) internal {
        if (foundation_ == address(0)) revert InvalidAddress();
        foundation = foundation_;
        emit FoundationUpdated(foundation_);
    }

    function setDefaultAdminPayout(address payout) external onlyAdmin {
        _setDefaultAdminPayout(payout);
    }

    function setDefaultAdminPayoutFor(
        address admin,
        address payout,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyAdminAction(
            admin,
            keccak256(abi.encode(SET_DEFAULT_ADMIN_PAYOUT_TYPEHASH, admin, payout, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!admins[admin]) revert Unauthorized();
        _setDefaultAdminPayout(payout);
    }

    function _setDefaultAdminPayout(address payout) internal {
        if (payout == address(0)) revert InvalidAddress();
        defaultAdminPayout = payout;
        emit DefaultAdminPayoutUpdated(payout);
    }

    /// @notice L0 updates an active child L1's share of the L0 10% node pool (0–10000 = 0–100%).
    function setL1Ratio(address l1, uint256 ratioBps) external onlyL0 {
        _setL1Ratio(msg.sender, l1, ratioBps);
    }

    function setL1RatioFor(
        address l0,
        address l1,
        uint256 ratioBps,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyAdminAction(
            l0,
            keccak256(abi.encode(SET_L1_RATIO_TYPEHASH, l0, l1, ratioBps, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!isActiveL0(l0)) revert NotL0();
        _setL1Ratio(l0, l1, ratioBps);
    }

    function _setL1Ratio(address l0, address l1, uint256 ratioBps) internal {
        if (l1 == address(0)) revert InvalidAddress();
        if (ratioBps > BPS) revert InvalidAmount();
        Member storage m = members[l1];
        if (m.role != Role.L1 || !m.active) revert NotL1();
        if (m.parentL0 != l0) revert Unauthorized();
        m.ratioBps = ratioBps;
        emit L1RatioUpdated(l1, l0, ratioBps);
    }

    function setWiring(address treasury_, address conetUsdc_) external onlyOwner {
        if (treasury_ == address(0) || conetUsdc_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
        conetUsdc = conetUsdc_;
        emit WiringUpdated(treasury_, conetUsdc_);
    }

    function l0Count() external view returns (uint256) {
        return _l0List.length;
    }

    function l0At(uint256 index) external view returns (address) {
        return _l0List[index];
    }

    function l0RedeemHashCount() external view returns (uint256) {
        return _l0RedeemHashes.length;
    }

    function l0RedeemHashAt(uint256 index) external view returns (bytes32) {
        return _l0RedeemHashes[index];
    }

    function l1Count() external view returns (uint256) {
        return _l1List.length;
    }

    function l1At(uint256 index) external view returns (address) {
        return _l1List[index];
    }

    function l1RedeemHashCount() external view returns (uint256) {
        return _l1RedeemHashes.length;
    }

    function l1RedeemHashAt(uint256 index) external view returns (bytes32) {
        return _l1RedeemHashes[index];
    }

    function isActiveL0(address account) public view returns (bool) {
        Member memory m = members[account];
        return m.role == Role.L0 && m.active;
    }

    function isActiveL1(address account) public view returns (bool) {
        Member memory m = members[account];
        return m.role == Role.L1 && m.active;
    }

    /// @notice Base per-node buckets (L0 pool before L1 cut, admin, foundation).
    function previewSplit(uint256 qty)
        public
        pure
        returns (uint256 l0Pool, uint256 adminAmount, uint256 foundationAmount, uint256 total)
    {
        return _previewSplit(qty, NODE_PRICE_USDC6, SERVER_FEE_USDC6, TOTAL_PER_NODE_USDC6);
    }

    /// @notice testMode buckets — same ratios as production at 1/1000 price (4.00 USDC / seat).
    function previewSplitTest(uint256 qty)
        public
        pure
        returns (uint256 l0Pool, uint256 adminAmount, uint256 foundationAmount, uint256 total)
    {
        return _previewSplit(qty, TEST_NODE_PRICE_USDC6, TEST_SERVER_FEE_USDC6, TEST_TOTAL_PER_NODE_USDC6);
    }

    /// @notice Apply L1 ratio to the L0 pool. `ratioBps` = share of L0's 10% (0–10000).
    function previewSplitWithL1(uint256 qty, uint256 ratioBps)
        public
        pure
        returns (uint256 l0Amount, uint256 l1Amount, uint256 adminAmount, uint256 foundationAmount, uint256 total)
    {
        if (ratioBps > BPS) revert InvalidAmount();
        uint256 l0Pool;
        (l0Pool, adminAmount, foundationAmount, total) = previewSplit(qty);
        l1Amount = (l0Pool * ratioBps) / BPS;
        l0Amount = l0Pool - l1Amount;
    }

    /// @notice Apply L1 ratio on testMode economics (4.00 USDC / seat).
    function previewSplitTestWithL1(uint256 qty, uint256 ratioBps)
        public
        pure
        returns (uint256 l0Amount, uint256 l1Amount, uint256 adminAmount, uint256 foundationAmount, uint256 total)
    {
        if (ratioBps > BPS) revert InvalidAmount();
        uint256 l0Pool;
        (l0Pool, adminAmount, foundationAmount, total) = previewSplitTest(qty);
        l1Amount = (l0Pool * ratioBps) / BPS;
        l0Amount = l0Pool - l1Amount;
    }

    function _previewSplit(
        uint256 qty,
        uint256 nodePriceUsdc6,
        uint256 serverFeeUsdc6,
        uint256 totalPerNodeUsdc6
    ) private pure returns (uint256 l0Pool, uint256 adminAmount, uint256 foundationAmount, uint256 total) {
        if (qty == 0) revert InvalidAmount();
        total = qty * totalPerNodeUsdc6;
        uint256 nodePortion = qty * nodePriceUsdc6;
        uint256 serverFee = qty * serverFeeUsdc6;
        l0Pool = (nodePortion * L0_OF_NODE_BPS) / BPS;
        adminAmount = serverFee + (nodePortion * ADMIN_OF_NODE_BPS) / BPS;
        foundationAmount = total - l0Pool - adminAmount;
    }

    function issueL0RedeemCode(bytes32 redeemHash) external onlyAdmin {
        _issueL0RedeemCode(msg.sender, redeemHash);
    }

    function issueL0RedeemCodeFor(
        address admin,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyAdminAction(
            admin,
            keccak256(abi.encode(ISSUE_L0_REDEEM_TYPEHASH, admin, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!admins[admin]) revert Unauthorized();
        _issueL0RedeemCode(admin, redeemHash);
    }

    function _issueL0RedeemCode(address admin, bytes32 redeemHash) internal {
        if (redeemHash == bytes32(0)) revert InvalidAmount();
        L0RedeemCode storage existing = l0RedeemCodes[redeemHash];
        if (existing.active || existing.claimed || existing.cancelled) revert CodeUnavailable();
        l0RedeemCodes[redeemHash] = L0RedeemCode(admin, true, false, false);
        _l0RedeemHashes.push(redeemHash);
        emit L0RedeemCodeIssued(redeemHash, admin);
    }

    function cancelL0RedeemCode(bytes32 redeemHash) external {
        _cancelL0RedeemCode(msg.sender, redeemHash);
    }

    function cancelL0RedeemCodeFor(
        address admin,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyAdminAction(
            admin,
            keccak256(abi.encode(CANCEL_L0_REDEEM_TYPEHASH, admin, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        _cancelL0RedeemCode(admin, redeemHash);
    }

    function _cancelL0RedeemCode(address admin, bytes32 redeemHash) internal {
        L0RedeemCode storage c = l0RedeemCodes[redeemHash];
        if (!c.active || c.claimed || c.cancelled || c.issuerAdmin != admin) revert Unauthorized();
        c.active = false;
        c.cancelled = true;
        emit L0RedeemCodeCancelled(redeemHash, admin);
    }

    function claimL0RedeemCode(bytes calldata secret) external nonReentrant {
        _claimL0RedeemCode(msg.sender, secret);
    }

    function claimL0RedeemCodeFor(
        address claimer,
        bytes calldata secret,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _verifyClaim(
            claimer,
            keccak256(abi.encode(CLAIM_L0_REDEEM_TYPEHASH, claimer, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (keccak256(bytes(secret)) != redeemHash) revert InvalidCode();
        _claimL0RedeemCode(claimer, secret);
    }

    function _claimL0RedeemCode(address claimer, bytes calldata secret) internal {
        bytes32 redeemHash = keccak256(bytes(secret));
        L0RedeemCode storage c = l0RedeemCodes[redeemHash];
        if (!c.active || c.claimed || c.cancelled) revert CodeUnavailable();
        if (admins[claimer] || members[claimer].role != Role.None) revert AlreadyRegistered();
        c.claimed = true;
        c.active = false;
        members[claimer] = Member(Role.L0, c.issuerAdmin, true, address(0), 0);
        _l0List.push(claimer);
        emit MemberRegistered(claimer, c.issuerAdmin);
        emit L0RedeemCodeClaimed(redeemHash, claimer, c.issuerAdmin);
    }

    /// @param ratioBps Share of L0's 10% node pool paid to the L1 (0–10000 = 0–100%).
    function issueL1RedeemCode(bytes32 redeemHash, uint256 ratioBps) external onlyL0 {
        _issueL1RedeemCode(msg.sender, redeemHash, ratioBps);
    }

    function issueL1RedeemCodeFor(
        address l0,
        bytes32 redeemHash,
        uint256 ratioBps,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyAdminAction(
            l0,
            keccak256(abi.encode(ISSUE_L1_REDEEM_TYPEHASH, l0, redeemHash, ratioBps, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!isActiveL0(l0)) revert NotL0();
        _issueL1RedeemCode(l0, redeemHash, ratioBps);
    }

    function _issueL1RedeemCode(address l0, bytes32 redeemHash, uint256 ratioBps) internal {
        if (redeemHash == bytes32(0) || ratioBps > BPS) revert InvalidAmount();
        L1RedeemCode storage existing = l1RedeemCodes[redeemHash];
        if (existing.active || existing.claimed || existing.cancelled) revert CodeUnavailable();
        l1RedeemCodes[redeemHash] = L1RedeemCode(l0, ratioBps, true, false, false);
        _l1RedeemHashes.push(redeemHash);
        emit L1RedeemCodeIssued(redeemHash, l0, ratioBps);
    }

    function cancelL1RedeemCode(bytes32 redeemHash) external {
        _cancelL1RedeemCode(msg.sender, redeemHash);
    }

    function cancelL1RedeemCodeFor(
        address l0,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyAdminAction(
            l0,
            keccak256(abi.encode(CANCEL_L1_REDEEM_TYPEHASH, l0, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        _cancelL1RedeemCode(l0, redeemHash);
    }

    function _cancelL1RedeemCode(address l0, bytes32 redeemHash) internal {
        L1RedeemCode storage c = l1RedeemCodes[redeemHash];
        if (!c.active || c.claimed || c.cancelled || c.issuerL0 != l0) revert Unauthorized();
        c.active = false;
        c.cancelled = true;
        emit L1RedeemCodeCancelled(redeemHash, l0);
    }

    function claimL1RedeemCode(bytes calldata secret) external nonReentrant {
        _claimL1RedeemCode(msg.sender, secret);
    }

    function claimL1RedeemCodeFor(
        address claimer,
        bytes calldata secret,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _verifyClaim(
            claimer,
            keccak256(abi.encode(CLAIM_L1_REDEEM_TYPEHASH, claimer, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (keccak256(bytes(secret)) != redeemHash) revert InvalidCode();
        _claimL1RedeemCode(claimer, secret);
    }

    function _claimL1RedeemCode(address claimer, bytes calldata secret) internal {
        bytes32 redeemHash = keccak256(bytes(secret));
        L1RedeemCode storage c = l1RedeemCodes[redeemHash];
        if (!c.active || c.claimed || c.cancelled) revert CodeUnavailable();
        if (admins[claimer] || members[claimer].role != Role.None) revert AlreadyRegistered();
        if (!isActiveL0(c.issuerL0)) revert NotL0();
        c.claimed = true;
        c.active = false;
        members[claimer] = Member(Role.L1, address(0), true, c.issuerL0, c.ratioBps);
        _l1List.push(claimer);
        emit L1MemberRegistered(claimer, c.issuerL0, c.ratioBps);
        emit L1RedeemCodeClaimed(redeemHash, claimer, c.issuerL0, c.ratioBps);
    }

    /// @notice Master binds sale before LockMint.
    /// @param referrer Zero, or an Admin (no L0 cut), active L0 (no L1 cut), or active L1 (ratio split).
    function bindSale(
        bytes32 operationId,
        address referrer,
        address buyer,
        uint256 qty,
        bool testMode
    ) external onlyBridgeBinder {
        if (operationId == bytes32(0) || buyer == address(0) || qty == 0) revert InvalidAmount();
        if (testMode && saleTestModePermanentlyDisabled) revert SaleTestModeNotAllowed();
        Sale storage s = sales[operationId];
        if (s.bound) revert SaleAlreadyBound();
        if (s.settled) revert SaleAlreadySettled();

        address referrerL0 = address(0);
        address referrerL1 = address(0);
        address referrerAdmin = address(0);
        if (referrer != address(0)) {
            if (isActiveL1(referrer)) {
                Member memory m = members[referrer];
                if (!isActiveL0(m.parentL0)) revert NotL0();
                referrerL1 = referrer;
                referrerL0 = m.parentL0;
            } else if (isActiveL0(referrer)) {
                referrerL0 = referrer;
            } else if (admins[referrer]) {
                referrerAdmin = referrer;
            } else {
                revert InvalidReferrer();
            }
        }

        sales[operationId] = Sale(referrerL0, buyer, qty, true, false, testMode, referrerL1, referrerAdmin);
        emit SaleBound(operationId, referrerL0, buyer, qty, testMode, referrerL1);
    }

    /// @inheritdoc ITreasuryBridgeMintCallback
    function onBridgeMint(
        bytes32 operationId,
        uint256 /* sourceChainId */,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts
    ) external nonReentrant {
        if (msg.sender != treasury) revert Unauthorized();
        if (destinationAsset != conetUsdc) {
            emit SaleUnboundSkipped(operationId, 0);
            return;
        }

        uint256 received;
        bool selfBeneficiary;
        uint256 len = beneficiaries.length;
        if (len != amounts.length) {
            emit SaleUnboundSkipped(operationId, 0);
            return;
        }
        for (uint256 i; i < len; ++i) {
            received += amounts[i];
            if (beneficiaries[i] == address(this)) selfBeneficiary = true;
        }
        if (!selfBeneficiary || received == 0) {
            emit SaleUnboundSkipped(operationId, received);
            return;
        }

        Sale storage s = sales[operationId];
        if (!s.bound || s.settled) {
            emit SaleUnboundSkipped(operationId, received);
            return;
        }

        (uint256 l0Pool, uint256 adminAmount, uint256 foundationAmount, uint256 expected) =
            s.testMode ? previewSplitTest(s.qty) : previewSplit(s.qty);
        if (received != expected) {
            emit SaleAmountMismatch(operationId, expected, received);
            emit SaleUnboundSkipped(operationId, received);
            return;
        }

        uint256 l0Amount = 0;
        uint256 l1Amount = 0;
        address l0Pay = address(0);
        address l1Pay = address(0);
        address adminPay = defaultAdminPayout;

        if (
            s.referrerL1 != address(0) && isActiveL1(s.referrerL1) && s.referrerL0 != address(0)
                && isActiveL0(s.referrerL0)
        ) {
            // L1 attribution → split L0 pool by L1 ratioBps.
            Member memory l1 = members[s.referrerL1];
            uint256 ratio = l1.ratioBps > BPS ? BPS : l1.ratioBps;
            l1Amount = (l0Pool * ratio) / BPS;
            l0Amount = l0Pool - l1Amount;
            l0Pay = s.referrerL0;
            l1Pay = s.referrerL1;
            address parent = members[s.referrerL0].parentAdmin;
            if (parent != address(0)) adminPay = parent;
        } else if (s.referrerL0 != address(0) && isActiveL0(s.referrerL0) && s.referrerL1 == address(0)) {
            // Bare L0 attribution → full L0 pool to L0; no L1 cut.
            l0Amount = l0Pool;
            l0Pay = s.referrerL0;
            address parent = members[s.referrerL0].parentAdmin;
            if (parent != address(0)) adminPay = parent;
        } else if (s.referrerAdmin != address(0) && admins[s.referrerAdmin]) {
            // Admin attribution → no L0/L1 cut; admin bucket to referring Admin.
            foundationAmount += l0Pool;
            adminPay = s.referrerAdmin;
        } else {
            // No / stale attribution → L0 pool folds into foundation.
            foundationAmount += l0Pool;
        }

        s.settled = true;
        if (l0Amount > 0) {
            _pay(l0Pay, l0Amount);
            earnedUsdc6[l0Pay] += l0Amount;
        }
        if (l1Amount > 0) {
            _pay(l1Pay, l1Amount);
            earnedUsdc6[l1Pay] += l1Amount;
        }
        if (adminAmount > 0) {
            _pay(adminPay, adminAmount);
            earnedUsdc6[adminPay] += adminAmount;
        }
        if (foundationAmount > 0) {
            _pay(foundation, foundationAmount);
            earnedUsdc6[foundation] += foundationAmount;
        }
        emit SaleSettled(
            operationId, l0Pay, l1Pay, adminPay, foundation, l0Amount, l1Amount, adminAmount, foundationAmount
        );
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0) || amount == 0) revert InvalidAddress();
        if (!IERC20GenesisReferral(token).transfer(to, amount)) revert TransferFailed();
        emit RescuedERC20(token, to, amount);
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!IERC20GenesisReferral(conetUsdc).transfer(to, amount)) revert TransferFailed();
    }

    function _verifyAdminAction(
        address signer,
        bytes32 structHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (redeemActionNonces[signer] != nonce) revert NonceUsed();
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator(), structHash);
        if (ECDSA.recover(digest, signature) != signer) revert InvalidSignature();
        redeemActionNonces[signer] = nonce + 1;
    }

    function _verifyClaim(
        address claimer,
        bytes32 structHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (claimNonces[claimer] != nonce) revert NonceUsed();
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator(), structHash);
        if (ECDSA.recover(digest, signature) != claimer) revert InvalidSignature();
        claimNonces[claimer] = nonce + 1;
    }

    uint256[37] private __gap;
}
