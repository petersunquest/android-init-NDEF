// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IConetProofVerifier} from "../external-treasury-immutable/IConetProofVerifier.sol";
import {IDepositUnit} from "./IDepositUnit.sol";
import {IUnitStateVerifier} from "./IUnitStateVerifier.sol";
import {DepositUnitFactory} from "./DepositUnitFactory.sol";

/// @title ExternalTreasuryUnits
/// @notice External-chain treasury that keeps each accepted deposit in a deposit unit (DU) of its own.
/// @dev A deposit derives its unit with CREATE2 and transfers the tokens straight into it, so the treasury holds nothing
///      at rest. A new unit is Registered and cannot pay until a verified state proof reports it Active. Payments draw
///      from Active units in first-in-first-out order chosen by the contract, never by the caller. A unit's status moves
///      only on a verified state or loss proof, and each proof must be newer than the last one accepted for that unit.
///      Every payment is atomic: if any unit transfer fails, nothing is paid and no burn or refund is consumed.
///      There is no owner, no pause, no upgrade path and no admin function.
contract ExternalTreasuryUnits is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant UNIT_NONE = 0;
    uint8 public constant UNIT_REGISTERED = 1;
    uint8 public constant UNIT_ACTIVE = 2;
    uint8 public constant UNIT_RESTRICTED = 3;
    uint8 public constant UNIT_RECON_PENDING = 4;
    uint8 public constant UNIT_SPENT = 5;
    uint8 public constant UNIT_LOSS_CONFIRMED = 6;

    /// @notice Most units one payment (release or refund) may draw from. Keeps gas bounded.
    uint256 public constant MAX_UNITS_PER_PAYMENT = 16;
    /// @notice Most queue entries one payment may scan, including skipped ones.
    uint256 public constant MAX_SCAN_PER_PAYMENT = 256;

    IConetProofVerifier public immutable VERIFIER;
    IUnitStateVerifier public immutable STATE_VERIFIER;
    DepositUnitFactory public immutable FACTORY;
    /// @notice A unit stays payable only while its last accepted proof is at most this many blocks old.
    uint256 public immutable MAX_PROOF_AGE;

    struct DepositRecord {
        address token;
        address depositor;
        address unit;
        uint256 amount;
        bytes32 beneficiaryCommitment;
        bool refunded;
    }

    struct UnitRecord {
        address token;
        uint8 status;
        uint256 remaining;
        uint256 lastProofBlock;
    }

    /// @notice Per-token principal by unit status. Principal D is registered + active + restricted + unverified.
    struct Buckets {
        uint256 registered;
        uint256 active;
        uint256 restricted;
        uint256 unverified;
        uint256 confirmedLoss;
    }

    mapping(address token => bool) public listed;
    mapping(address token => uint256) public cap;
    mapping(address token => uint256) public appliedVersion;
    mapping(bytes32 burnId => bool) public burnConsumed;
    mapping(bytes32 depositId => DepositRecord) public deposits;
    mapping(address unit => UnitRecord) public units;
    mapping(address token => Buckets) public buckets;
    uint256 public depositNonce;

    mapping(address token => address[]) private _queue;
    mapping(address token => uint256) private _head;

    event AllowlistApplied(address indexed token, bool add, uint256 version, uint256 cap);
    event Deposited(
        bytes32 indexed depositId,
        address indexed token,
        address indexed depositor,
        address unit,
        uint256 amount,
        bytes32 beneficiaryCommitment,
        uint256 nonce
    );
    event UnitStateReported(address indexed unit, uint8 status, uint256 balance, uint256 blockNumber);
    event LossConfirmed(address indexed unit, uint256 amount, uint256 blockNumber);
    event Released(bytes32 indexed burnId, address indexed token, address indexed recipient, uint256 amount);
    event Refunded(bytes32 indexed depositId, address indexed depositor, address indexed token, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroCommitment();
    error ZeroProofAge();
    error LengthMismatch();
    error ImplementationNotDeployed();
    error NotListed(address token);
    error OverCap(uint256 received, uint256 cap);
    error UnsupportedTokenSemantics(uint256 expected, uint256 received);
    error WrongTarget();
    error StaleVersion(uint256 applied, uint256 offered);
    error CodeHashMismatch();
    error AlreadyConsumed();
    error UnknownDeposit();
    error AlreadyRefunded();
    error RefundMismatch();
    error UnknownUnit(address unit);
    error UnitClosed(address unit);
    error WrongToken(address proven, address bound);
    error FutureProof(uint256 blockNumber);
    error StaleProof(uint256 last, uint256 offered);
    error StaleUnitState(address unit, uint256 lastProofBlock);
    error LossOutOfRange(uint256 amount, uint256 remaining);
    error InsufficientActiveReserves(uint256 available, uint256 required);
    error TooManyUnits();
    error ScanLimitExceeded();
    error InvalidStatus(uint8 status);

    constructor(
        IConetProofVerifier verifier_,
        IUnitStateVerifier stateVerifier_,
        address unitImplementation_,
        uint256 maxProofAge_,
        address[] memory tokens_,
        uint256[] memory caps_
    ) {
        if (address(verifier_) == address(0) || address(stateVerifier_) == address(0)) revert ZeroAddress();
        if (unitImplementation_.code.length == 0) revert ImplementationNotDeployed();
        if (maxProofAge_ == 0) revert ZeroProofAge();
        if (tokens_.length != caps_.length) revert LengthMismatch();
        VERIFIER = verifier_;
        STATE_VERIFIER = stateVerifier_;
        MAX_PROOF_AGE = maxProofAge_;
        FACTORY = new DepositUnitFactory(address(this), unitImplementation_);
        for (uint256 i; i < tokens_.length; ++i) {
            if (tokens_[i] == address(0)) revert ZeroAddress();
            if (caps_[i] == 0) revert ZeroAmount();
            listed[tokens_[i]] = true;
            cap[tokens_[i]] = caps_[i];
            emit AllowlistApplied(tokens_[i], true, 0, caps_[i]);
        }
    }

    /// @notice Applies a CoNET whitelist message. Anyone may submit it; the proof is the only authority.
    function applyAllowlist(bytes calldata proof) external {
        IConetProofVerifier.Allowlist memory m = VERIFIER.verifyAllowlist(proof);
        if (m.chainId != block.chainid || m.treasury != address(this)) revert WrongTarget();
        uint256 applied = appliedVersion[m.token];
        if (m.version <= applied) revert StaleVersion(applied, m.version);
        appliedVersion[m.token] = m.version;
        if (m.add) {
            if (m.cap == 0) revert ZeroAmount();
            if (m.codeHash != bytes32(0) && m.token.codehash != m.codeHash) revert CodeHashMismatch();
            listed[m.token] = true;
            cap[m.token] = m.cap;
        } else {
            listed[m.token] = false;
            cap[m.token] = 0;
        }
        emit AllowlistApplied(m.token, m.add, m.version, m.cap);
    }

    /// @notice Deposits a listed token into a unit of its own. The depositor's transfer is the authorisation, and
    ///         `beneficiaryCommitment` binds the CoNET-side beneficiary of this deposit.
    /// @return depositId Binds this chain, this treasury, the token, the depositor, the amount, the commitment and a nonce.
    function deposit(address token, uint256 amount, bytes32 beneficiaryCommitment)
        external
        nonReentrant
        returns (bytes32 depositId)
    {
        if (!listed[token]) revert NotListed(token);
        if (amount == 0) revert ZeroAmount();
        if (beneficiaryCommitment == bytes32(0)) revert ZeroCommitment();
        if (amount > cap[token]) revert OverCap(amount, cap[token]);

        uint256 nonce = depositNonce++;
        depositId = keccak256(
            abi.encode(block.chainid, address(this), token, msg.sender, amount, beneficiaryCommitment, nonce)
        );
        address unit = FACTORY.createUnit(depositId, token);

        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(unit);
        asset.safeTransferFrom(msg.sender, unit, amount);
        // Only tokens that deliver exactly `amount` are accepted. Fee, rebasing and other semantics are not modelled.
        uint256 received = asset.balanceOf(unit) - balanceBefore;
        if (received != amount) revert UnsupportedTokenSemantics(amount, received);

        deposits[depositId] = DepositRecord({
            token: token,
            depositor: msg.sender,
            unit: unit,
            amount: amount,
            beneficiaryCommitment: beneficiaryCommitment,
            refunded: false
        });
        // Proofs about this unit must post-date its creation, so an earlier state cannot activate it.
        units[unit] = UnitRecord({
            token: token,
            status: UNIT_REGISTERED,
            remaining: amount,
            lastProofBlock: block.number
        });
        _queue[token].push(unit);
        _adjust(token, UNIT_REGISTERED, amount, true);
        emit Deposited(depositId, token, msg.sender, unit, amount, beneficiaryCommitment, nonce);
    }

    /// @notice Releases against a verified CoNET burn. The payment comes from Active units, first in first out.
    function release(bytes calldata proof) external nonReentrant {
        IConetProofVerifier.Burn memory b = VERIFIER.verifyBurn(proof);
        if (b.chainId != block.chainid || b.treasury != address(this)) revert WrongTarget();
        if (burnConsumed[b.burnId]) revert AlreadyConsumed();
        burnConsumed[b.burnId] = true;
        _pay(b.token, b.amount, b.recipient);
        emit Released(b.burnId, b.token, b.recipient, b.amount);
    }

    /// @notice Refunds a deposit that was never minted after its route was disabled. Paid once, from Active units.
    function refund(bytes calldata proof) external nonReentrant {
        IConetProofVerifier.Refund memory r = VERIFIER.verifyRefund(proof);
        if (r.chainId != block.chainid || r.treasury != address(this)) revert WrongTarget();
        DepositRecord storage d = deposits[r.depositId];
        if (d.amount == 0) revert UnknownDeposit();
        if (d.refunded) revert AlreadyRefunded();
        if (d.token != r.token || d.depositor != r.depositor || d.amount != r.amount) revert RefundMismatch();
        d.refunded = true;
        _pay(d.token, d.amount, d.depositor);
        emit Refunded(r.depositId, d.depositor, d.token, d.amount);
    }

    /// @notice Sets a unit's status from a verified state proof: Restricted, ReconciliationPending or Active.
    ///         Anyone may submit it. The proof must be newer than the last one accepted for that unit.
    function reportUnitState(bytes calldata proof) external nonReentrant {
        IUnitStateVerifier.UnitState memory s = STATE_VERIFIER.verifyUnitState(proof);
        if (s.chainId != block.chainid || s.treasury != address(this)) revert WrongTarget();
        UnitRecord storage u = units[s.unit];
        if (u.status == UNIT_NONE) revert UnknownUnit(s.unit);
        if (_isClosed(u.status)) revert UnitClosed(s.unit);
        if (s.token != u.token) revert WrongToken(s.token, u.token);
        _checkProofBlock(u, s.blockNumber);
        u.lastProofBlock = s.blockNumber;

        uint8 next = UNIT_ACTIVE;
        if (s.restricted) {
            next = UNIT_RESTRICTED;
        } else if (s.balance < u.remaining) {
            next = UNIT_RECON_PENDING;
        }
        _moveUnit(s.unit, next);
        emit UnitStateReported(s.unit, next, s.balance, s.blockNumber);
    }

    /// @notice Writes off part of a unit's registered principal on a verified loss proof. A unit whose principal is
    ///         fully written off becomes LossConfirmed. A failed transfer is never treated as a loss.
    function confirmLoss(bytes calldata proof) external nonReentrant {
        IUnitStateVerifier.UnitLoss memory l = STATE_VERIFIER.verifyUnitLoss(proof);
        if (l.chainId != block.chainid || l.treasury != address(this)) revert WrongTarget();
        UnitRecord storage u = units[l.unit];
        if (u.status == UNIT_NONE) revert UnknownUnit(l.unit);
        if (_isClosed(u.status)) revert UnitClosed(l.unit);
        if (l.token != u.token) revert WrongToken(l.token, u.token);
        if (l.amount == 0 || l.amount > u.remaining) revert LossOutOfRange(l.amount, u.remaining);
        _checkProofBlock(u, l.blockNumber);
        u.lastProofBlock = l.blockNumber;

        _adjust(u.token, u.status, l.amount, false);
        u.remaining -= l.amount;
        buckets[u.token].confirmedLoss += l.amount;
        if (u.remaining == 0) u.status = UNIT_LOSS_CONFIRMED;
        emit LossConfirmed(l.unit, l.amount, l.blockNumber);
    }

    /// @notice The unit that holds the deposit, or the zero address for an unknown deposit.
    function unitOf(bytes32 depositId) external view returns (address) {
        return deposits[depositId].unit;
    }

    /// @notice Registered principal not yet paid, refunded or written off (D in the whitepaper).
    function principalOf(address token) external view returns (uint256) {
        Buckets storage b = buckets[token];
        return b.registered + b.active + b.restricted + b.unverified;
    }

    /// @notice The units and amounts a payment of `amount` would draw now. Reverts with the reason the payment would hit.
    function previewPayment(address token, uint256 amount)
        external
        view
        returns (address[] memory selected, uint256[] memory takes)
    {
        return _select(token, amount);
    }

    /// @notice Number of units ever queued for a token (closed units stay in the queue).
    function queueLength(address token) external view returns (uint256) {
        return _queue[token].length;
    }

    /// @notice Index of the first queue entry that is not closed.
    function queueHead(address token) external view returns (uint256) {
        return _head[token];
    }

    /// @notice The queue entry at `index` for a token.
    function queuedUnit(address token, uint256 index) external view returns (address) {
        return _queue[token][index];
    }

    /// @dev Chooses the units for a payment of `amount`: Active units only, first in first out, at most
    ///      MAX_UNITS_PER_PAYMENT of them, each with a proof no older than MAX_PROOF_AGE blocks.
    function _select(address token, uint256 amount)
        private
        view
        returns (address[] memory selected, uint256[] memory takes)
    {
        if (amount == 0) revert ZeroAmount();
        address[] storage queue = _queue[token];
        address[] memory picked = new address[](MAX_UNITS_PER_PAYMENT);
        uint256[] memory amounts = new uint256[](MAX_UNITS_PER_PAYMENT);
        uint256 count;
        uint256 remaining = amount;
        uint256 scanned;
        for (uint256 i = _head[token]; i < queue.length && remaining > 0; ++i) {
            if (++scanned > MAX_SCAN_PER_PAYMENT) revert ScanLimitExceeded();
            address unit = queue[i];
            UnitRecord storage u = units[unit];
            if (u.status != UNIT_ACTIVE) continue;
            if (block.number > u.lastProofBlock + MAX_PROOF_AGE) revert StaleUnitState(unit, u.lastProofBlock);
            if (count == MAX_UNITS_PER_PAYMENT) revert TooManyUnits();
            uint256 take = u.remaining < remaining ? u.remaining : remaining;
            picked[count] = unit;
            amounts[count] = take;
            ++count;
            remaining -= take;
        }
        if (remaining > 0) revert InsufficientActiveReserves(amount - remaining, amount);
        selected = new address[](count);
        takes = new uint256[](count);
        for (uint256 j; j < count; ++j) {
            selected[j] = picked[j];
            takes[j] = amounts[j];
        }
    }

    /// @dev Pays `amount` of `token` to `to` from the units `_select` chooses. Any failed transfer reverts the whole call.
    function _pay(address token, uint256 amount, address to) private {
        if (to == address(0)) revert ZeroAddress();
        (address[] memory selected, uint256[] memory takes) = _select(token, amount);
        for (uint256 j; j < selected.length; ++j) {
            UnitRecord storage u = units[selected[j]];
            u.remaining -= takes[j];
            _adjust(token, UNIT_ACTIVE, takes[j], false);
            if (u.remaining == 0) u.status = UNIT_SPENT;
            IDepositUnit(selected[j]).pay(to, takes[j]);
        }
        _advanceHead(token);
    }

    /// @dev A proof must name a block that exists and be newer than the last one accepted for the unit.
    function _checkProofBlock(UnitRecord storage u, uint256 blockNumber) private view {
        if (blockNumber > block.number) revert FutureProof(blockNumber);
        if (blockNumber <= u.lastProofBlock) revert StaleProof(u.lastProofBlock, blockNumber);
    }

    /// @dev Moves a unit to `next` and carries its remaining principal from one bucket to the other.
    function _moveUnit(address unit, uint8 next) private {
        UnitRecord storage u = units[unit];
        if (u.status == next) return;
        _adjust(u.token, u.status, u.remaining, false);
        _adjust(u.token, next, u.remaining, true);
        u.status = next;
    }

    /// @dev Adds `amount` to, or removes it from, the bucket that holds units in `status`.
    function _adjust(address token, uint8 status, uint256 amount, bool add) private {
        Buckets storage b = buckets[token];
        if (status == UNIT_REGISTERED) {
            b.registered = _step(b.registered, amount, add);
        } else if (status == UNIT_ACTIVE) {
            b.active = _step(b.active, amount, add);
        } else if (status == UNIT_RESTRICTED) {
            b.restricted = _step(b.restricted, amount, add);
        } else if (status == UNIT_RECON_PENDING) {
            b.unverified = _step(b.unverified, amount, add);
        } else {
            revert InvalidStatus(status);
        }
    }

    function _step(uint256 value, uint256 amount, bool add) private pure returns (uint256) {
        return add ? value + amount : value - amount;
    }

    function _isClosed(uint8 status) private pure returns (bool) {
        return status == UNIT_SPENT || status == UNIT_LOSS_CONFIRMED;
    }

    /// @dev Moves the head past closed units at the front of the queue, so later scans start at live units.
    function _advanceHead(address token) private {
        address[] storage queue = _queue[token];
        uint256 h = _head[token];
        while (h < queue.length && _isClosed(units[queue[h]].status)) ++h;
        _head[token] = h;
    }
}
