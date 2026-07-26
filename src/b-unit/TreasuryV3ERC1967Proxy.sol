// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Local artifact wrapper so Hardhat exports the proxy bytecode used by
/// deterministic Treasury V3 deployment scripts and tests.
contract TreasuryV3ERC1967Proxy is ERC1967Proxy {
    constructor(address implementation, bytes memory initData)
        ERC1967Proxy(implementation, initData)
    {}
}
