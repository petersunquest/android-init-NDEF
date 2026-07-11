// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title ConetLabMiningPool
 * @notice CoNET Lab mining pool: receives native CoNET (CNET) as the beneficiary of Lab-held
 *         staked / voting validators, and lets admins withdraw (single or batch).
 * @dev UUPS upgradeable (ERC1967 proxy) so the canonical address stays stable for use as
 *      `fee_recipient` / reward payout address. Multi-admin mapping matches ValidatorDepositRedeem.
 */
contract ConetLabMiningPool is Initializable, UUPSUpgradeable {
    /// @notice Admins: may withdraw native CNET, manage admins, and authorize upgrades.
    mapping(address => bool) public admins;

    /// @dev Minimal non-reentrancy guard for native CNET withdrawals (1 = unlocked, 2 = locked).
    uint256 private _nativeLock;

    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event NativeReceived(address indexed from, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);

    error NotAdmin();
    error ZeroAddress();
    error ZeroAmount();
    error LengthMismatch();
    error EmptyBatch();
    error InsufficientBalance();
    error TransferFailed();
    error Reentrant();
    error CannotRemoveSelf();

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

    /// @notice Accept native CoNET (CNET) deposits (validator rewards, direct transfers, etc.).
    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param initialAdmin Initial admin (withdraw / admin management / upgrade authority).
     */
    function initialize(address initialAdmin) external initializer {
        __UUPSUpgradeable_init();
        if (initialAdmin == address(0)) revert ZeroAddress();
        _nativeLock = 1;
        admins[initialAdmin] = true;
        emit AdminAdded(initialAdmin);
    }

    /// @notice Admin-only: transfer native CoNET (CNET) held by the contract to a recipient.
    function withdrawNative(address to, uint256 amount) external onlyAdmin nonReentrantNative {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientBalance();
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit NativeWithdrawn(to, amount);
    }

    /// @notice Admin-only: batch transfer native CoNET (CNET) to many recipients in one transaction.
    /// @param recipients Parallel recipient addresses (must be non-zero).
    /// @param amounts    Parallel CNET amounts (wei, 18 decimals); each must be > 0.
    function withdrawNativeBatch(address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyAdmin
        nonReentrantNative
    {
        if (recipients.length != amounts.length) revert LengthMismatch();
        if (recipients.length == 0) revert EmptyBatch();
        uint256 total = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        if (address(this).balance < total) revert InsufficientBalance();
        for (uint256 i = 0; i < recipients.length; i++) {
            address to = recipients[i];
            uint256 amount = amounts[i];
            if (to == address(0)) revert ZeroAddress();
            if (amount == 0) revert ZeroAmount();
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
            emit NativeWithdrawn(to, amount);
        }
    }

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

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    /// @dev Storage gap for future upgrades (keep canonical proxy address stable).
    uint256[50] private __gap;
}
