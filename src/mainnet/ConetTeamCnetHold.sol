// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ConetTeamCnetHold
 * @notice CoNET team reserved native CNET hold with redeem-admin offline issuance and a
 *         global 36-month linear release queue.
 * @dev Flow:
 *      1) Redeem admin EIP-712-signs CreateHoldRedeem(codeHash, amount, …); relay calls
 *         {createRedeem} (secret code never on-chain — hash only).
 *      2) {consumeRedeem} places `amount` into `slots[to]` and increases {totalAllocated}.
 *      3) Beneficiaries {claimVested} with beneficiary EIP-712; owner claims residual
 *         unallocated share via {claimOwnerUnallocated} (no signature).
 *      4) Owner may update {startTimestamp} via {setStartTimestamp} when it does not
 *         undercut already-released amounts.
 *      Prefer funding the full reservation before {startTimestamp}.
 */
contract ConetTeamCnetHold is Initializable, UUPSUpgradeable {
    using ECDSA for bytes32;

    /// @notice Linear vesting duration: 36 months ≈ 36 × 30 days.
    uint64 public constant DURATION = uint64(36 * 30 days);

    bytes32 private constant _EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("ConetTeamCnetHold");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");

    bytes32 public constant CREATE_HOLD_REDEEM_TYPEHASH = keccak256(
        "CreateHoldRedeem(bytes32 codeHash,uint256 amount,uint64 validAfter,uint64 validBefore,uint256 nonce)"
    );
    bytes32 public constant CLAIM_HOLD_VESTED_TYPEHASH = keccak256(
        "ClaimHoldVested(address beneficiary,uint256 amount,uint64 deadline,uint256 nonce)"
    );

    struct VestingSlot {
        uint256 allocation;
        uint256 released;
    }

    struct RedeemOffer {
        uint256 amount;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
    }

    /// @notice Residual-pool owner (creator). Receives linear unlock of {unallocated}.
    address public owner;
    /// @notice Unix timestamp when linear vesting begins.
    uint64 public startTimestamp;

    /// @notice Sum of all redeem-claimed allocations.
    uint256 public totalAllocated;
    /// @notice Sum of all native CNET paid out (beneficiaries + owner residual).
    uint256 public totalReleased;
    /// @notice Cumulative residual-pool CNET already claimed by {owner}.
    uint256 public ownerReleased;

    mapping(address => VestingSlot) public slots;
    mapping(bytes32 => RedeemOffer) public redeems;

    mapping(address => bool) public admins;
    mapping(address => bool) public redeemAdmins;
    mapping(address => uint256) public redeemAdminNonces;
    mapping(address => uint256) public beneficiaryNonces;

    bytes32 private _eip712CachedSeparator;
    bytes32 private _eip712CachedChainId;

    /// @dev Minimal non-reentrancy guard for native payouts (1 = unlocked, 2 = locked).
    uint256 private _nativeLock;

    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event RedeemAdminAdded(address indexed admin);
    event RedeemAdminRemoved(address indexed admin);
    event NativeReceived(address indexed from, uint256 amount);
    event RedeemCreated(bytes32 indexed codeHash, uint256 amount, uint64 validAfter, uint64 validBefore, address indexed admin);
    event RedeemConsumed(bytes32 indexed codeHash, address indexed to, uint256 amount);
    event VestedClaimed(address indexed beneficiary, uint256 amount);
    event OwnerUnallocatedClaimed(address indexed owner, uint256 amount);
    event StartTimestampUpdated(uint64 previousStart, uint64 newStart);

    error NotAdmin();
    error NotOwner();
    error NotRedeemAdmin();
    error ZeroAddress();
    error ZeroStart();
    error ZeroAmount();
    error ZeroCodeHash();
    error RedeemExists();
    error RedeemInactive();
    error InvalidTimeWindow();
    error BadNonce();
    error BadSignature();
    error Expired();
    error InsufficientUnallocated();
    error OwnerOverAllocated();
    error ExceedsReleasable();
    error InsufficientBalance();
    error TransferFailed();
    error Reentrant();
    error CannotRemoveSelf();
    error EmptyCode();
    error StartWouldUndercutReleased();

    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert NotAdmin();
        _;
    }

    modifier nonReentrantNative() {
        if (_nativeLock != 1) revert Reentrant();
        _nativeLock = 2;
        _;
        _nativeLock = 1;
    }

    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param owner_ Residual / creator wallet (claims unallocated vesting).
     * @param startTimestamp_ Vesting start (unix seconds); must be > 0.
     * @param initialAdmin_ UUPS / role admin.
     * @param initialRedeemAdmin_ First redeem admin (may equal initialAdmin_).
     */
    function initialize(
        address owner_,
        uint64 startTimestamp_,
        address initialAdmin_,
        address initialRedeemAdmin_
    ) external initializer {
        __UUPSUpgradeable_init();
        if (owner_ == address(0) || initialAdmin_ == address(0) || initialRedeemAdmin_ == address(0)) {
            revert ZeroAddress();
        }
        if (startTimestamp_ == 0) revert ZeroStart();
        _nativeLock = 1;
        owner = owner_;
        startTimestamp = startTimestamp_;
        admins[initialAdmin_] = true;
        redeemAdmins[initialRedeemAdmin_] = true;
        _initEip712Domain();
        emit AdminAdded(initialAdmin_);
        emit RedeemAdminAdded(initialRedeemAdmin_);
    }

    // -------------------------------------- Views --------------------------------------

    function endTimestamp() public view returns (uint64) {
        return startTimestamp + DURATION;
    }

    /// @notice All CNET accounted in the hold (`balance + totalReleased`).
    function poolPrincipal() public view returns (uint256) {
        return address(this).balance + totalReleased;
    }

    /// @notice CNET not yet assigned via redeem consume.
    function unallocated() public view returns (uint256) {
        uint256 principal = poolPrincipal();
        uint256 allocated = totalAllocated;
        return principal > allocated ? principal - allocated : 0;
    }

    /// @notice Owner residual allocation equals current {unallocated}.
    function ownerAllocation() external view returns (uint256) {
        return unallocated();
    }

    function allocationOf(address account) external view returns (uint256) {
        return slots[account].allocation;
    }

    function releasedOf(address account) external view returns (uint256) {
        return slots[account].released;
    }

    function vestedOf(address account, uint64 timestamp) public view returns (uint256) {
        return _vested(slots[account].allocation, timestamp);
    }

    function releasableOf(address account) public view returns (uint256) {
        uint256 vested = vestedOf(account, uint64(block.timestamp));
        uint256 done = slots[account].released;
        return vested > done ? vested - done : 0;
    }

    function ownerVested(uint64 timestamp) public view returns (uint256) {
        return _vested(unallocated(), timestamp);
    }

    function ownerReleasable() public view returns (uint256) {
        uint256 vested = ownerVested(uint64(block.timestamp));
        return vested > ownerReleased ? vested - ownerReleased : 0;
    }

    function getRedeem(bytes32 codeHash)
        external
        view
        returns (uint256 amount, uint64 validAfter, uint64 validBefore, bool active)
    {
        RedeemOffer storage r = redeems[codeHash];
        return (r.amount, r.validAfter, r.validBefore, r.active);
    }

    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashCreateHoldRedeem(
        bytes32 codeHash,
        uint256 amount,
        uint64 validAfter,
        uint64 validBefore,
        uint256 nonce
    ) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(CREATE_HOLD_REDEEM_TYPEHASH, codeHash, amount, validAfter, validBefore, nonce))
        );
    }

    function hashClaimHoldVested(address beneficiary, uint256 amount, uint64 deadline, uint256 nonce)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(CLAIM_HOLD_VESTED_TYPEHASH, beneficiary, amount, deadline, nonce))
        );
    }

    // -------------------------------------- Redeem issue / consume --------------------------------------

    /**
     * @notice Relay a redeem-admin EIP-712 CreateHoldRedeem. Stores hash + amount only.
     */
    function createRedeem(
        bytes32 codeHash,
        uint256 amount,
        uint64 validAfter,
        uint64 validBefore,
        address admin,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (codeHash == bytes32(0)) revert ZeroCodeHash();
        if (amount == 0) revert ZeroAmount();
        if (admin == address(0)) revert ZeroAddress();
        if (!redeemAdmins[admin]) revert NotRedeemAdmin();
        if (redeemAdminNonces[admin] != nonce) revert BadNonce();
        if (validBefore != 0 && validBefore < validAfter) revert InvalidTimeWindow();
        if (redeems[codeHash].active || redeems[codeHash].amount != 0) revert RedeemExists();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(CREATE_HOLD_REDEEM_TYPEHASH, codeHash, amount, validAfter, validBefore, nonce))
        );
        address signer = digest.recover(signature);
        if (signer != admin) revert BadSignature();

        redeemAdminNonces[admin] = nonce + 1;
        redeems[codeHash] = RedeemOffer({
            amount: amount,
            validAfter: validAfter,
            validBefore: validBefore,
            active: true
        });
        emit RedeemCreated(codeHash, amount, validAfter, validBefore, admin);
    }

    /**
     * @notice Consume a secret redeem code and enqueue `to` for linear release of the signed amount.
     * @dev Secret `code` is only used to derive `keccak256(bytes(code))`; not stored.
     */
    function consumeRedeem(string calldata code, address to) external nonReentrantNative {
        if (to == address(0)) revert ZeroAddress();
        bytes memory b = bytes(code);
        if (b.length == 0) revert EmptyCode();
        bytes32 codeHash = keccak256(b);
        RedeemOffer storage r = redeems[codeHash];
        if (!r.active) revert RedeemInactive();
        if (!_timeOk(r.validAfter, r.validBefore)) revert InvalidTimeWindow();

        uint256 amount = r.amount;
        r.active = false;

        uint256 free = unallocated();
        if (amount > free) revert InsufficientUnallocated();

        uint256 newUnalloc = free - amount;
        // Owner must not have already drawn more residual than remains vested after this allocation.
        if (ownerReleased > _vested(newUnalloc, uint64(block.timestamp))) revert OwnerOverAllocated();

        slots[to].allocation += amount;
        totalAllocated += amount;
        emit RedeemConsumed(codeHash, to, amount);
    }

    // -------------------------------------- Vesting claims --------------------------------------

    /**
     * @notice Claim unlocked CNET for a redeem beneficiary. Requires beneficiary EIP-712 signature.
     */
    function claimVested(
        address beneficiary,
        uint256 amount,
        uint64 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external nonReentrantNative {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert Expired();
        if (beneficiaryNonces[beneficiary] != nonce) revert BadNonce();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(CLAIM_HOLD_VESTED_TYPEHASH, beneficiary, amount, deadline, nonce))
        );
        address signer = digest.recover(signature);
        if (signer != beneficiary) revert BadSignature();

        uint256 avail = releasableOf(beneficiary);
        if (amount > avail) revert ExceedsReleasable();

        beneficiaryNonces[beneficiary] = nonce + 1;
        slots[beneficiary].released += amount;
        totalReleased += amount;
        _pay(beneficiary, amount);
        emit VestedClaimed(beneficiary, amount);
    }

    /**
     * @notice Owner claims unlocked portion of the unallocated residual pool (no signature).
     */
    function claimOwnerUnallocated(uint256 amount) external nonReentrantNative {
        if (msg.sender != owner) revert NotOwner();
        if (amount == 0) revert ZeroAmount();
        uint256 avail = ownerReleasable();
        if (amount > avail) revert ExceedsReleasable();

        ownerReleased += amount;
        totalReleased += amount;
        _pay(owner, amount);
        emit OwnerUnallocatedClaimed(owner, amount);
    }

    /**
     * @notice Owner may update the global vesting start date.
     * @dev Reverts if the new schedule would make already-released amounts exceed vested
     *      totals for allocations or the owner residual pool at `block.timestamp`.
     */
    function setStartTimestamp(uint64 newStart) external {
        if (msg.sender != owner) revert NotOwner();
        if (newStart == 0) revert ZeroStart();

        uint64 previous = startTimestamp;
        if (newStart == previous) return;

        startTimestamp = newStart;

        uint64 nowTs = uint64(block.timestamp);
        uint256 beneficiaryReleased = totalReleased - ownerReleased;
        if (_vested(totalAllocated, nowTs) < beneficiaryReleased) {
            startTimestamp = previous;
            revert StartWouldUndercutReleased();
        }
        if (_vested(unallocated(), nowTs) < ownerReleased) {
            startTimestamp = previous;
            revert StartWouldUndercutReleased();
        }

        emit StartTimestampUpdated(previous, newStart);
    }

    // -------------------------------------- Admin --------------------------------------

    function addAdmin(address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        admins[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyAdmin {
        if (account == msg.sender) revert CannotRemoveSelf();
        admins[account] = false;
        emit AdminRemoved(account);
    }

    function addRedeemAdmin(address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        redeemAdmins[account] = true;
        emit RedeemAdminAdded(account);
    }

    function removeRedeemAdmin(address account) external onlyAdmin {
        redeemAdmins[account] = false;
        emit RedeemAdminRemoved(account);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    // -------------------------------------- Internals --------------------------------------

    function _vested(uint256 allocation, uint64 timestamp) internal view returns (uint256) {
        if (allocation == 0) return 0;
        uint64 start = startTimestamp;
        if (timestamp < start) return 0;
        uint64 end = start + DURATION;
        if (timestamp >= end) return allocation;
        return (allocation * uint256(timestamp - start)) / uint256(DURATION);
    }

    function _timeOk(uint64 validAfter, uint64 validBefore) internal view returns (bool) {
        uint256 t = block.timestamp;
        if (t < uint256(validAfter)) return false;
        if (validBefore != 0 && t > uint256(validBefore)) return false;
        return true;
    }

    function _pay(address to, uint256 amount) internal {
        if (address(this).balance < amount) revert InsufficientBalance();
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _initEip712Domain() private {
        _eip712CachedChainId = bytes32(block.chainid);
        _eip712CachedSeparator = keccak256(
            abi.encode(_EIP712_TYPE_HASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (bytes32(block.chainid) == _eip712CachedChainId) {
            return _eip712CachedSeparator;
        }
        return keccak256(
            abi.encode(_EIP712_TYPE_HASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    /// @dev Storage gap for future upgrades.
    uint256[38] private __gap;
}
