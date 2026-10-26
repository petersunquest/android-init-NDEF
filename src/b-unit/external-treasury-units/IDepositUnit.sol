// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice What the factory and the treasury may call on a deposit unit. No other entry point moves funds.
interface IDepositUnit {
    function initialize(address treasury_, address token_) external;

    function pay(address to, uint256 amount) external;

    function treasury() external view returns (address);

    function token() external view returns (address);
}
