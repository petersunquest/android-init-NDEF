// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Lab stand-in for ValidatorDepositRedeem escalate surfaces.
///      PM / members must NOT pass addAdmin / setRedeemAdmin / withdrawNative.
contract MockVdrPaymentLine {
    address public owner;
    mapping(address => bool) public admins;
    mapping(address => bool) public redeemAdmins;

    error NotOwner();
    error NotAdmin();
    error ZeroAddress();

    event AdminAdded(address indexed account);
    event RedeemAdminSet(address indexed account, bool enabled);
    event NativeWithdrawn(address indexed to, uint256 amount);

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        admins[owner_] = true;
    }

    receive() external payable {}

    function addAdmin(address account) external {
        if (msg.sender != owner && !admins[msg.sender]) revert NotAdmin();
        if (account == address(0)) revert ZeroAddress();
        admins[account] = true;
        emit AdminAdded(account);
    }

    function setRedeemAdmin(address account, bool enabled) external {
        if (msg.sender != owner && !admins[msg.sender]) revert NotAdmin();
        if (account == address(0)) revert ZeroAddress();
        redeemAdmins[account] = enabled;
        emit RedeemAdminSet(account, enabled);
    }

    function withdrawNative(address payable to, uint256 amount) external {
        if (!admins[msg.sender]) revert NotAdmin();
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        require(ok, "withdraw failed");
        emit NativeWithdrawn(to, amount);
    }

    /// @dev Lab helper: deposit "CL" balance for payoutBatch pulls.
    function fund() external payable {}
}
