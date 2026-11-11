// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LabLineMemberManagedExecutor
/// @notice Lab-only least-privilege payout proxy for ONE payment line.
///         - owner: caps, pause, memberManager, ownership (NOT day-to-day members)
///         - memberManager (PM): setMember / topUpMemberGas only
///         - members: payoutBatch only
///         - vdr + linePool immutable (no TipSink-as-VDR redirect)
/// @dev Not for production until PROD-PENDING-REVIEW is approved.
contract LabLineMemberManagedExecutor {
    address public owner;
    address public memberManager;

    /// @dev Settlement source (must be VDR-class; immutable).
    address public immutable vdr;
    /// @dev Fixed per-line recipient pool (immutable).
    address payable public immutable linePool;
    /// @dev Opaque line id for off-chain registry / events (not used on-chain for auth).
    bytes32 public immutable paymentLineId;

    mapping(address => bool) public members;

    bool public paused;
    uint256 public maxPayoutWei;
    uint256 public maxBatchTotalWei;
    uint256 public maxGasTopUpWei;
    uint256 public maxGasTopUpPeriodWei;
    uint256 public gasTopUpPeriodSeconds;
    uint256 public gasTopUpPeriodStart;
    uint256 public gasTopUpPeriodSpent;

    mapping(bytes32 => bool) public usedBatchKeys;
    mapping(bytes32 => bool) public usedEventKeys;

    error NotOwner();
    error NotMemberManager();
    error NotExecutor();
    error NotMember();
    error ZeroAddress();
    error Paused();
    error BadCap();
    error BatchEmpty();
    error BatchTooLarge();
    error PayoutTooLarge();
    error BatchKeyUsed();
    error EventKeyUsed();
    error TransferFailed();
    error GasTopUpTooLarge();
    error GasTopUpPeriodExceeded();
    error InsufficientGasPurse();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MemberManagerSet(address indexed previous, address indexed next);
    event MemberSet(address indexed account, bool enabled);
    event CapsUpdated(
        uint256 maxPayoutWei,
        uint256 maxBatchTotalWei,
        uint256 maxGasTopUpWei,
        uint256 maxGasTopUpPeriodWei,
        uint256 gasTopUpPeriodSeconds
    );
    event PausedSet(bool paused);
    event GasTopUp(address indexed member, uint256 amount, address indexed by);
    event PayoutBatch(
        address indexed executor,
        bytes32 indexed batchKey,
        bytes32 indexed eventKey,
        uint256 totalWei,
        uint256 count
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyMemberManager() {
        if (msg.sender != memberManager) revert NotMemberManager();
        _;
    }

    constructor(
        address owner_,
        address vdr_,
        address payable linePool_,
        bytes32 paymentLineId_,
        uint256 maxPayoutWei_,
        uint256 maxBatchTotalWei_,
        uint256 maxGasTopUpWei_,
        uint256 maxGasTopUpPeriodWei_,
        uint256 gasTopUpPeriodSeconds_
    ) {
        if (owner_ == address(0) || vdr_ == address(0) || linePool_ == address(0)) {
            revert ZeroAddress();
        }
        if (maxPayoutWei_ == 0 || maxBatchTotalWei_ == 0 || maxGasTopUpWei_ == 0) {
            revert BadCap();
        }
        owner = owner_;
        vdr = vdr_;
        linePool = linePool_;
        paymentLineId = paymentLineId_;
        maxPayoutWei = maxPayoutWei_;
        maxBatchTotalWei = maxBatchTotalWei_;
        maxGasTopUpWei = maxGasTopUpWei_;
        maxGasTopUpPeriodWei = maxGasTopUpPeriodWei_;
        gasTopUpPeriodSeconds = gasTopUpPeriodSeconds_ == 0 ? 1 days : gasTopUpPeriodSeconds_;
        gasTopUpPeriodStart = block.timestamp;
        emit OwnershipTransferred(address(0), owner_);
        emit CapsUpdated(
            maxPayoutWei_,
            maxBatchTotalWei_,
            maxGasTopUpWei_,
            maxGasTopUpPeriodWei_,
            gasTopUpPeriodSeconds
        );
    }

    receive() external payable {}

    // ─── owner ─────────────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setMemberManager(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit MemberManagerSet(memberManager, next);
        memberManager = next;
    }

    function setCaps(
        uint256 maxPayoutWei_,
        uint256 maxBatchTotalWei_,
        uint256 maxGasTopUpWei_,
        uint256 maxGasTopUpPeriodWei_,
        uint256 gasTopUpPeriodSeconds_
    ) external onlyOwner {
        if (maxPayoutWei_ == 0 || maxBatchTotalWei_ == 0 || maxGasTopUpWei_ == 0) {
            revert BadCap();
        }
        maxPayoutWei = maxPayoutWei_;
        maxBatchTotalWei = maxBatchTotalWei_;
        maxGasTopUpWei = maxGasTopUpWei_;
        maxGasTopUpPeriodWei = maxGasTopUpPeriodWei_;
        gasTopUpPeriodSeconds = gasTopUpPeriodSeconds_ == 0 ? 1 days : gasTopUpPeriodSeconds_;
        emit CapsUpdated(
            maxPayoutWei_,
            maxBatchTotalWei_,
            maxGasTopUpWei_,
            maxGasTopUpPeriodWei_,
            gasTopUpPeriodSeconds
        );
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    // ─── memberManager (PM) ────────────────────────────────────────────────

    function setMember(address account, bool enabled) external onlyMemberManager {
        if (account == address(0)) revert ZeroAddress();
        members[account] = enabled;
        emit MemberSet(account, enabled);
    }

    /// @notice Alias for setMember — mirrors LabMiningPoolPayoutExecutor naming.
    function setExecutor(address account, bool enabled) external onlyMemberManager {
        if (account == address(0)) revert ZeroAddress();
        members[account] = enabled;
        emit MemberSet(account, enabled);
    }

    /// @notice Restricted gas top-up from this contract's ETH purse to a current member.
    function topUpMemberGas(address payable member, uint256 amount) external onlyMemberManager {
        if (paused) revert Paused();
        if (!members[member]) revert NotMember();
        if (amount == 0 || amount > maxGasTopUpWei) revert GasTopUpTooLarge();

        if (block.timestamp >= gasTopUpPeriodStart + gasTopUpPeriodSeconds) {
            gasTopUpPeriodStart = block.timestamp;
            gasTopUpPeriodSpent = 0;
        }
        uint256 nextSpent = gasTopUpPeriodSpent + amount;
        if (maxGasTopUpPeriodWei > 0 && nextSpent > maxGasTopUpPeriodWei) {
            revert GasTopUpPeriodExceeded();
        }
        if (address(this).balance < amount) revert InsufficientGasPurse();

        gasTopUpPeriodSpent = nextSpent;
        (bool ok,) = member.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit GasTopUp(member, amount, msg.sender);
    }

    // ─── members (settlement) ──────────────────────────────────────────────

    /// @dev Lab simplified payout: pull `amounts[i]` from this contract's balance
    ///      (pre-funded to simulate VDR skim credit) into immutable linePool.
    ///      Production wiring would call VDR skim with fixed recipient = linePool.
    function payoutBatch(
        bytes32 batchKey,
        bytes32 eventKey,
        uint256[] calldata amounts
    ) external {
        if (paused) revert Paused();
        if (!members[msg.sender]) revert NotExecutor();
        if (amounts.length == 0) revert BatchEmpty();
        if (usedBatchKeys[batchKey]) revert BatchKeyUsed();
        if (usedEventKeys[eventKey]) revert EventKeyUsed();

        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 a = amounts[i];
            if (a == 0 || a > maxPayoutWei) revert PayoutTooLarge();
            total += a;
        }
        if (total > maxBatchTotalWei) revert BatchTooLarge();
        if (address(this).balance < total) revert TransferFailed();

        usedBatchKeys[batchKey] = true;
        usedEventKeys[eventKey] = true;

        (bool ok,) = linePool.call{value: total}("");
        if (!ok) revert TransferFailed();

        emit PayoutBatch(msg.sender, batchKey, eventKey, total, amounts.length);
    }

    function gasPurseBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
