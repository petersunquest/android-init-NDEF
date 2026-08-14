// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title TreasuryCanonicalERC20V3
/// @notice Canonical bridge token controlled by TreasuryBridgeV3.
/// @dev Mint: **only** BRIDGE_ROLE / TREASURY_ROLE (treasury address). Not developers / EOAs / Registry.
///      Burn: treasury/bridge **or** BURN_ROLE (FX Registry settle burns only — no mint).
///      GB→Canonical mint must go TreasuryBridgeV3.mintDeveloperFxFromRegistry (msg.sender=treasury).
///      Native wrap: lock native CNET ↔ mint/burn wCNET 1:1 when enabled.
contract TreasuryCanonicalERC20V3 is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    /// @notice Fee-settlement / treasury mint path (e.g. TreasuryBridgeV3 B-Unit fee mint).
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    /// @notice Settlement burn-only (DeveloperTokenFxRegistry). Cannot mint.
    bytes32 public constant BURN_ROLE = keccak256("BURN_ROLE");
    bytes32 public constant WITHDRAW_TYPEHASH = keccak256(
        "Withdraw(address user,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint8 private _tokenDecimals;
    string public contractURI;

    /// @notice When true, `deposit` / `withdraw*` accept native CNET (CoNET only).
    bool public nativeWrapEnabled;
    /// @notice Per-user nonce for `withdrawWithSignature`.
    mapping(address => uint256) public withdrawNonces;

    /// @dev Appended in V3.1 upgrade — EIP-2612 / EIP-3009 (storage-safe after withdrawNonces).
    mapping(address => uint256) private _permitNonces;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    /// @dev TreasuryBridgeV3 — reads min stake / miner gas refund; only it may bind this policy.
    address public developerStakeTreasury;
    /// @dev Native CONET locked as developer FX qualification stake (not native-wrap reserve).
    uint256 public developerCnetStake;

    error InvalidAddress();
    error InvalidMetadata();
    error NativeWrapDisabled();
    error InsufficientNativeReserve();
    error SignatureExpired();
    error InvalidSignature();
    error InvalidAmount();
    error NativeTransferFailed();
    error AuthorizationNotYetValid(uint256 validAfter);
    error AuthorizationExpired(uint256 validBefore);
    error AuthorizationAlreadyUsed(address authorizer, bytes32 nonce);
    error DeveloperStakeNotEnabled();
    error UnauthorizedDeveloperStake();
    error InsufficientDeveloperStake();
    error PrivilegedRoleUseSetter();

    event NativeWrapEnabledUpdated(bool enabled);
    event BurnRoleUpdated(address indexed account, bool enabled);
    event NativeDeposited(address indexed account, uint256 amount);
    event NativeWithdrawn(address indexed account, address indexed recipient, uint256 amount);
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    /// @notice Owner swept an arbitrary ERC20 held by this contract (e.g. PayByUse surplus GB).
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event DeveloperStakeTreasuryBound(address indexed treasury);
    event DeveloperStakeDeposited(address indexed from, uint256 amount, uint256 stakeTotal);
    event MinerGasRefunded(address indexed miner, uint256 amount, uint256 stakeRemaining);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        address admin_,
        address bridge_,
        string calldata contractURI_
    ) external initializer {
        if (admin_ == address(0) || bridge_ == address(0)) revert InvalidAddress();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert InvalidMetadata();
        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _tokenDecimals = decimals_;
        contractURI = contractURI_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(BRIDGE_ROLE, bridge_);
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _checkMinter(msg.sender);
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _checkBurner(msg.sender);
        _burn(account, amount);
    }

    function setBridge(address bridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bridge_ == address(0)) revert InvalidAddress();
        _grantRole(BRIDGE_ROLE, bridge_);
    }

    function revokeBridge(address bridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(BRIDGE_ROLE, bridge_);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert InvalidAddress();
        _grantRole(TREASURY_ROLE, treasury_);
    }

    function revokeTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(TREASURY_ROLE, treasury_);
    }

    /// @notice Grant burn-only role (FX Registry settle). Does **not** confer mint.
    function setBurner(address burner_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (burner_ == address(0)) revert InvalidAddress();
        _grantRole(BURN_ROLE, burner_);
        emit BurnRoleUpdated(burner_, true);
    }

    function revokeBurner(address burner_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(BURN_ROLE, burner_);
        emit BurnRoleUpdated(burner_, false);
    }

    /// @dev Block admin from `grantRole(TREASURY/BRIDGE/BURN, eoa)` — use dedicated setters only.
    function grantRole(bytes32 role, address account)
        public
        override
        onlyRole(getRoleAdmin(role))
    {
        if (role == TREASURY_ROLE || role == BRIDGE_ROLE || role == BURN_ROLE) {
            revert PrivilegedRoleUseSetter();
        }
        super.grantRole(role, account);
    }

    function _checkMinter(address account) internal view {
        if (!hasRole(BRIDGE_ROLE, account) && !hasRole(TREASURY_ROLE, account)) {
            revert AccessControlUnauthorizedAccount(account, TREASURY_ROLE);
        }
    }

    function _checkBurner(address account) internal view {
        if (
            !hasRole(BRIDGE_ROLE, account) && !hasRole(TREASURY_ROLE, account)
                && !hasRole(BURN_ROLE, account)
        ) {
            revert AccessControlUnauthorizedAccount(account, BURN_ROLE);
        }
    }

    function setContractURI(string calldata contractURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        contractURI = contractURI_;
    }

    function setNativeWrapEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        nativeWrapEnabled = enabled;
        emit NativeWrapEnabledUpdated(enabled);
    }

    /**
     * @notice Owner rescues any ERC20 balance held by this contract (PayByUse surplus GB, mistaken sends).
     * @dev Mint path remains treasury/bridge-only — no free airdrop mint. Supply enters via USDC→treasury.
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert NativeTransferFailed();
        emit ERC20Rescued(token, to, amount);
    }

    /**
     * @notice Bind TreasuryBridgeV3 as stake-policy authority (min CNET stake + miner gas refund).
     * @dev Callable by DEFAULT_ADMIN or TREASURY_ROLE (treasury issues developer FX).
     */
    function bindDeveloperStakeTreasury(address treasury_) external {
        if (treasury_ == address(0)) revert InvalidAddress();
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(TREASURY_ROLE, msg.sender)) {
            revert UnauthorizedDeveloperStake();
        }
        developerStakeTreasury = treasury_;
        emit DeveloperStakeTreasuryBound(treasury_);
    }

    /// @notice Lock native CONET as developer FX qualification stake (treasury-gated).
    function depositDeveloperStake() external payable {
        _creditDeveloperStake(msg.sender, msg.value);
    }

    /// @notice Native CNET stake currently locked for treasury qualification.
    function developerStakeBalance() external view returns (uint256) {
        return developerCnetStake;
    }

    /**
     * @notice True iff stake ≥ treasury `developerTokenMinStakeWei` (unqualified → treasury will not forward).
     */
    function isTreasuryQualified() public view returns (bool) {
        address t = developerStakeTreasury;
        if (t == address(0)) return false;
        uint256 minStake = ITreasuryDeveloperFxPolicy(t).developerTokenMinStakeWei();
        if (minStake == 0) return false;
        return developerCnetStake >= minStake;
    }

    /**
     * @notice Pay miner gas refund from developer stake (Settlement / treasury only).
     * @dev Amount = treasury `developerTokenMinerGasRefundWei`. Reduces stake; below min → unqualified.
     */
    function refundMinerGas(address miner) external returns (uint256 paid) {
        address t = developerStakeTreasury;
        if (t == address(0)) revert DeveloperStakeNotEnabled();
        if (miner == address(0)) revert InvalidAddress();
        address settlement = ITreasuryDeveloperFxPolicy(t).depinGbSettlement();
        if (msg.sender != settlement && msg.sender != t) revert UnauthorizedDeveloperStake();

        paid = ITreasuryDeveloperFxPolicy(t).developerTokenMinerGasRefundWei();
        if (paid == 0) return 0;
        if (developerCnetStake < paid) revert InsufficientDeveloperStake();
        if (address(this).balance < paid) revert InsufficientNativeReserve();

        unchecked {
            developerCnetStake -= paid;
        }
        (bool ok,) = payable(miner).call{value: paid}("");
        if (!ok) revert NativeTransferFailed();
        emit MinerGasRefunded(miner, paid, developerCnetStake);
    }

    function _creditDeveloperStake(address from, uint256 amount) internal {
        if (developerStakeTreasury == address(0)) revert DeveloperStakeNotEnabled();
        if (amount == 0) revert InvalidAmount();
        developerCnetStake += amount;
        emit DeveloperStakeDeposited(from, amount, developerCnetStake);
    }

    /// @notice Lock native CNET and mint the same amount of wCNET to the caller.
    function deposit() external payable {
        _deposit(msg.sender, msg.value);
    }

    receive() external payable {
        if (developerStakeTreasury != address(0) && !nativeWrapEnabled) {
            _creditDeveloperStake(msg.sender, msg.value);
            return;
        }
        _deposit(msg.sender, msg.value);
    }

    /// @notice Burn caller's wCNET and release native CNET 1:1.
    function withdraw(uint256 amount) external {
        _withdraw(msg.sender, msg.sender, amount);
    }

    /// @notice Offline-signed unwrap: user signs EIP-712; anyone may relay and pay gas.
    /// @dev Burns `user`'s wCNET without allowance; native is sent to `recipient`.
    function withdrawWithSignature(
        address user,
        address recipient,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (withdrawNonces[user] != nonce) revert InvalidSignature();

        bytes32 digest = getWithdrawDigest(user, recipient, amount, nonce, deadline);
        address signer = ECDSA.recover(digest, signature);
        if (signer != user) revert InvalidSignature();

        withdrawNonces[user] = nonce + 1;
        _withdraw(user, recipient, amount);
    }

    /// @notice EIP-712 digest for `withdrawWithSignature` (frontend `signTypedDataV4`).
    function getWithdrawDigest(
        address user,
        address recipient,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(WITHDRAW_TYPEHASH, user, recipient, amount, nonce, deadline)
        );
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    /// @dev Domain for native unwrap signatures (legacy name lock).
    function _domainSeparatorV4() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("TreasuryCanonicalERC20V3")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @dev EIP-2612 / EIP-3009 domain uses ERC20 `name()` (wallet-standard).
    function _permitDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name())),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _permitDomainSeparator();
    }

    function nonces(address owner) external view returns (uint256) {
        return _permitNonces[owner];
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, _permitNonces[owner]++, deadline)
        );
        address signer = ECDSA.recover(
            MessageHashUtils.toTypedDataHash(_permitDomainSeparator(), structHash),
            signature
        );
        if (signer != owner) revert InvalidSignature();
        _approve(owner, spender, value);
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid(validAfter);
        if (block.timestamp >= validBefore) revert AuthorizationExpired(validBefore);
        if (authorizationState[from][nonce]) revert AuthorizationAlreadyUsed(from, nonce);
        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        address signer = ECDSA.recover(
            MessageHashUtils.toTypedDataHash(_permitDomainSeparator(), structHash),
            signature
        );
        if (signer != from) revert InvalidSignature();
        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    function _deposit(address account, uint256 amount) internal {
        if (!nativeWrapEnabled) revert NativeWrapDisabled();
        if (amount == 0) revert InvalidAmount();
        _mint(account, amount);
        emit NativeDeposited(account, amount);
    }

    function _withdraw(address account, address recipient, uint256 amount) internal {
        if (!nativeWrapEnabled) revert NativeWrapDisabled();
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (address(this).balance < amount) revert InsufficientNativeReserve();

        _burn(account, amount);
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativeWithdrawn(account, recipient, amount);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}

    /// @dev Gap: wrap + nonces + permit + auth + developerStakeTreasury + developerCnetStake.
    uint256[39] private __gap;
}

interface ITreasuryDeveloperFxPolicy {
    function developerTokenMinStakeWei() external view returns (uint256);
    function developerTokenMinerGasRefundWei() external view returns (uint256);
    function depinGbSettlement() external view returns (address);
}
