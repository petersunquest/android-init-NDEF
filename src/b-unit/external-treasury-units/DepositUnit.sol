// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDepositUnit} from "./IDepositUnit.sol";

/// @title DepositUnit
/// @notice Holds the external token of one accepted deposit and pays out only when the treasury instructs it.
/// @dev Deployed as an ERC-1167 clone by DepositUnitFactory with CREATE2. The implementation is marked bound in its
///      constructor, so it can never be initialised. Each clone is bound once, by the factory, in the same transaction
///      that creates it. There is no owner, no admin, no upgrade path and no arbitrary delegatecall. `pay` is the only
///      function that moves funds, and it accepts calls from the bound treasury alone. A failed transfer reverts.
contract DepositUnit is IDepositUnit {
    using SafeERC20 for IERC20;

    address public treasury;
    address public token;
    address public factory;
    bool private _bound;

    error AlreadyBound();
    error ZeroAddress();
    error NotTreasury();

    event Bound(address indexed treasury, address indexed token, address indexed factory);

    constructor() {
        _bound = true; // the implementation itself can never be bound
    }

    /// @notice Binds a clone to its treasury and token. Called once, by the factory, in the same transaction as the clone.
    function initialize(address treasury_, address token_) external {
        if (_bound) revert AlreadyBound();
        if (treasury_ == address(0) || token_ == address(0)) revert ZeroAddress();
        _bound = true;
        factory = msg.sender;
        treasury = treasury_;
        token = token_;
        emit Bound(treasury_, token_, msg.sender);
    }

    /// @notice Pays `amount` of the bound token to `to`. Reverts on any failure.
    function pay(address to, uint256 amount) external {
        if (msg.sender != treasury) revert NotTreasury();
        IERC20(token).safeTransfer(to, amount);
    }
}
