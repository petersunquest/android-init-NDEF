// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only USDC-like token: 6 decimals, a per-address blacklist that blocks transfers to and from an address,
///         and a global pause, which the issuer controls in the real token.
contract DepositUnitMockUSDC is ERC20 {
    error TokenPaused();
    error Blacklisted(address account);

    bool public paused;
    mapping(address account => bool) public blacklisted;

    constructor() ERC20("Deposit Unit Mock USDC", "dUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setBlacklisted(address account, bool value) external {
        blacklisted[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert TokenPaused();
        if (from != address(0) && blacklisted[from]) revert Blacklisted(from);
        if (to != address(0) && blacklisted[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}
