// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev Minimal Base USDC (Circle FiatTokenV2_2) surface used by the splitter:
///      - {transfer} / {balanceOf} for the Method B (settle-then-distribute) path.
///      - EIP-3009 {receiveWithAuthorization} (bytes-signature overload) for the Method A
///        atomic path, where USDC is pulled into this contract and split in one transaction.
interface IUSDC {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

/**
 * @title NodeSaleSplitter
 * @notice On-Base USDC payment splitter for CoNET node purchases. Each node costs a fixed
 *         {nodePriceUsdc6} (settled to {treasury}) plus a {serverFeeUsdc6} server fee (settled to
 *         {serverFeeRecipient}); the gross per node is the sum. Two settlement paths are supported:
 *
 *           Method B (primary, x402 facilitator): the x402 facilitator settles the full gross
 *             (1370 USDC * N) into this contract via USDC transferWithAuthorization (auth.to = this
 *             contract). A CoNET relayer/admin then calls {distribute} to split the funds and emit
 *             {NodePurchaseSettled} carrying the buyer's beneficiary/claim address for off-chain
 *             redeem-code issuance.
 *
 *           Method A (atomic): {purchaseNodes} pulls the exact gross via EIP-3009
 *             receiveWithAuthorization and splits in a single transaction (permissionless; anyone may
 *             relay a valid USDC authorization signed by the payer).
 *
 * @dev UUPS upgradeable (ERC1967 proxy) so the canonical Base address stays stable across upgrades.
 *      Funds only ever move to the fixed {treasury} / {serverFeeRecipient}; {distribute} is admin-only
 *      purely to keep accounting/event emission aligned with the off-chain order pipeline. Prices and
 *      recipient addresses are admin-tunable. {purchaseRef} (e.g. the USDC settle tx hash or order id)
 *      provides on-chain idempotency against double settlement.
 */
contract NodeSaleSplitter is Initializable, UUPSUpgradeable {
    /// @notice Base USDC token (6 decimals).
    IUSDC public usdc;
    /// @notice Recipient of the node principal portion (CoNET treasury on Base).
    address public treasury;
    /// @notice Recipient of the per-node server fee portion.
    address public serverFeeRecipient;
    /// @notice Node principal price per node, 6 decimals (e.g. 1250 USDC = 1_250_000_000).
    uint256 public nodePriceUsdc6;
    /// @notice Server fee per node, 6 decimals (e.g. 120 USDC = 120_000_000).
    uint256 public serverFeeUsdc6;
    /// @notice Admins: may {distribute}, tune config, rescue tokens and authorize upgrades.
    mapping(address => bool) public admins;
    /// @notice On-chain idempotency guard keyed by an off-chain purchase reference.
    mapping(bytes32 => bool) public usedPurchaseRef;

    uint256 private constant _MAX_NODE_COUNT = 10_000;

    event AdminUpdated(address indexed admin, bool enabled);
    event RecipientsUpdated(address indexed treasury, address indexed serverFeeRecipient);
    event PricesUpdated(uint256 nodePriceUsdc6, uint256 serverFeeUsdc6);
    event NodePurchaseSettled(
        address indexed caller,
        address indexed claimAddress,
        uint256 nodeCount,
        uint256 gross,
        uint256 toTreasury,
        uint256 toServerFee,
        bytes32 indexed purchaseRef
    );
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    error NotAdmin();
    error ZeroAddress();
    error BadNodeCount();
    error RefAlreadyUsed();
    error ValueMismatch();
    error InsufficientBalance();
    error TransferFailed();

    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert NotAdmin();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param usdc_ Base USDC token address.
     * @param treasury_ Node principal recipient (treasury).
     * @param serverFeeRecipient_ Server fee recipient.
     * @param nodePriceUsdc6_ Node principal per node (6 decimals).
     * @param serverFeeUsdc6_ Server fee per node (6 decimals).
     * @param admin_ Initial admin (distribute / config / upgrade authority).
     */
    function initialize(
        address usdc_,
        address treasury_,
        address serverFeeRecipient_,
        uint256 nodePriceUsdc6_,
        uint256 serverFeeUsdc6_,
        address admin_
    ) external initializer {
        __UUPSUpgradeable_init();
        if (
            usdc_ == address(0) ||
            treasury_ == address(0) ||
            serverFeeRecipient_ == address(0) ||
            admin_ == address(0)
        ) revert ZeroAddress();
        usdc = IUSDC(usdc_);
        treasury = treasury_;
        serverFeeRecipient = serverFeeRecipient_;
        nodePriceUsdc6 = nodePriceUsdc6_;
        serverFeeUsdc6 = serverFeeUsdc6_;
        admins[admin_] = true;
        emit AdminUpdated(admin_, true);
        emit RecipientsUpdated(treasury_, serverFeeRecipient_);
        emit PricesUpdated(nodePriceUsdc6_, serverFeeUsdc6_);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Gross USDC (6 decimals) required for `nodeCount` nodes.
    function grossForNodes(uint256 nodeCount) public view returns (uint256) {
        return (nodePriceUsdc6 + serverFeeUsdc6) * nodeCount;
    }

    /// @notice Split breakdown for `nodeCount` nodes: (toTreasury, toServerFee, gross).
    function splitForNodes(uint256 nodeCount)
        public
        view
        returns (uint256 toTreasury, uint256 toServerFee, uint256 gross)
    {
        toTreasury = nodePriceUsdc6 * nodeCount;
        toServerFee = serverFeeUsdc6 * nodeCount;
        gross = toTreasury + toServerFee;
    }

    // -------------------------------------------------------------------------
    // Settlement
    // -------------------------------------------------------------------------

    /**
     * @notice Method B: split USDC that has already been settled into this contract (by the x402
     *         facilitator) for a node purchase. Admin/relayer-only so the emitted event stays aligned
     *         with the off-chain order pipeline that issues the redeem code to {claimAddress}.
     * @param nodeCount Number of nodes purchased.
     * @param claimAddress Buyer beneficiary / claim address (recorded in the event for redeem issuance).
     * @param purchaseRef Off-chain idempotency reference (e.g. USDC settle tx hash); single-use.
     */
    function distribute(uint256 nodeCount, address claimAddress, bytes32 purchaseRef) external onlyAdmin {
        if (nodeCount == 0 || nodeCount > _MAX_NODE_COUNT) revert BadNodeCount();
        if (usedPurchaseRef[purchaseRef]) revert RefAlreadyUsed();
        usedPurchaseRef[purchaseRef] = true;

        (uint256 toTreasury, uint256 toServerFee, uint256 gross) = splitForNodes(nodeCount);
        if (usdc.balanceOf(address(this)) < gross) revert InsufficientBalance();

        _safeTransfer(treasury, toTreasury);
        _safeTransfer(serverFeeRecipient, toServerFee);

        emit NodePurchaseSettled(msg.sender, claimAddress, nodeCount, gross, toTreasury, toServerFee, purchaseRef);
    }

    /**
     * @notice Method A (atomic): pull the exact gross via EIP-3009 receiveWithAuthorization and split in
     *         one transaction. Permissionless — anyone may relay a USDC authorization signed by the payer
     *         (`from`) with `to` = this contract. Funds can only land at the fixed recipients.
     * @param nodeCount Number of nodes purchased.
     * @param claimAddress Buyer beneficiary / claim address (recorded in the event for redeem issuance).
     * @param purchaseRef Off-chain idempotency reference; single-use.
     * @param from Payer (USDC authorization signer).
     * @param value Authorized USDC value; must equal grossForNodes(nodeCount).
     * @param validAfter EIP-3009 validAfter.
     * @param validBefore EIP-3009 validBefore.
     * @param nonce EIP-3009 nonce.
     * @param signature EIP-3009 signature bytes.
     */
    function purchaseNodes(
        uint256 nodeCount,
        address claimAddress,
        bytes32 purchaseRef,
        address from,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (nodeCount == 0 || nodeCount > _MAX_NODE_COUNT) revert BadNodeCount();
        if (usedPurchaseRef[purchaseRef]) revert RefAlreadyUsed();

        (uint256 toTreasury, uint256 toServerFee, uint256 gross) = splitForNodes(nodeCount);
        if (value != gross) revert ValueMismatch();
        usedPurchaseRef[purchaseRef] = true;

        // receiveWithAuthorization requires msg.sender == `to`, i.e. this contract.
        usdc.receiveWithAuthorization(from, address(this), value, validAfter, validBefore, nonce, signature);

        _safeTransfer(treasury, toTreasury);
        _safeTransfer(serverFeeRecipient, toServerFee);

        emit NodePurchaseSettled(from, claimAddress, nodeCount, gross, toTreasury, toServerFee, purchaseRef);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setAdmin(address account, bool enabled) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        admins[account] = enabled;
        emit AdminUpdated(account, enabled);
    }

    function setRecipients(address treasury_, address serverFeeRecipient_) external onlyAdmin {
        if (treasury_ == address(0) || serverFeeRecipient_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        serverFeeRecipient = serverFeeRecipient_;
        emit RecipientsUpdated(treasury_, serverFeeRecipient_);
    }

    function setPrices(uint256 nodePriceUsdc6_, uint256 serverFeeUsdc6_) external onlyAdmin {
        nodePriceUsdc6 = nodePriceUsdc6_;
        serverFeeUsdc6 = serverFeeUsdc6_;
        emit PricesUpdated(nodePriceUsdc6_, serverFeeUsdc6_);
    }

    /// @notice Rescue stuck tokens (e.g. a non-USDC token mistakenly sent here, or surplus dust).
    function rescueToken(address token, address to, uint256 amount) external onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        if (!IUSDC(token).transfer(to, amount)) revert TransferFailed();
        emit TokenRescued(token, to, amount);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _safeTransfer(address to, uint256 amount) private {
        if (amount == 0) return;
        if (!usdc.transfer(to, amount)) revert TransferFailed();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    /// @dev Storage gap for future upgrades (keep canonical address stable).
    uint256[43] private __gap;
}
