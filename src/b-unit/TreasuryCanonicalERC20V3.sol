// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title TreasuryCanonicalERC20V3
/// @notice Canonical bridge token controlled by TreasuryBridgeV3.
/// @dev On CoNET, admin may enable native wrap: lock native CNET ↔ mint/burn wCNET 1:1.
///      Bridge burns leave native locked as reserve for Base-side supply; unwrap is capped
///      by `address(this).balance`.
contract TreasuryCanonicalERC20V3 is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    /// @notice Fee-settlement / treasury mint path (e.g. TreasuryBridgeV3 B-Unit fee mint).
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant WITHDRAW_TYPEHASH = keccak256(
        "Withdraw(address user,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    uint8 private _tokenDecimals;
    string public contractURI;

    /// @notice When true, `deposit` / `withdraw*` accept native CNET (CoNET only).
    bool public nativeWrapEnabled;
    /// @notice Per-user nonce for `withdrawWithSignature`.
    mapping(address => uint256) public withdrawNonces;

    error InvalidAddress();
    error InvalidMetadata();
    error NativeWrapDisabled();
    error InsufficientNativeReserve();
    error SignatureExpired();
    error InvalidSignature();
    error InvalidAmount();
    error NativeTransferFailed();

    event NativeWrapEnabledUpdated(bool enabled);
    event NativeDeposited(address indexed account, uint256 amount);
    event NativeWithdrawn(address indexed account, address indexed recipient, uint256 amount);

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
        _checkBridgeOrTreasury(msg.sender);
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _checkBridgeOrTreasury(msg.sender);
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

    function _checkBridgeOrTreasury(address account) internal view {
        if (!hasRole(BRIDGE_ROLE, account) && !hasRole(TREASURY_ROLE, account)) {
            revert AccessControlUnauthorizedAccount(account, BRIDGE_ROLE);
        }
    }

    function setContractURI(string calldata contractURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        contractURI = contractURI_;
    }

    function setNativeWrapEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        nativeWrapEnabled = enabled;
        emit NativeWrapEnabledUpdated(enabled);
    }

    /// @notice Lock native CNET and mint the same amount of wCNET to the caller.
    function deposit() external payable {
        _deposit(msg.sender, msg.value);
    }

    receive() external payable {
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

    /// @dev Gap reduced by 2 for `nativeWrapEnabled` + `withdrawNonces`.
    uint256[43] private __gap;
}
