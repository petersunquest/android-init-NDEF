// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @notice Thin wrapper so Hardhat emits an artifact for OZ BeaconProxy.
/// @dev Factory CREATE initCode is this constructor + `initialize` calldata.
///      The card address is the proxy and stays stable when the beacon implementation is upgraded.
contract BeamioUserCardBeaconProxy is BeaconProxy {
    constructor(address beacon, bytes memory data) payable BeaconProxy(beacon, data) {}
}
