// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Upgradeable beacon for BeamioUserCard BeaconProxy cards (address-stable, logic-upgradable).
contract BeamioUserCardUpgradeableBeacon is UpgradeableBeacon {
    constructor(address implementation_, address initialOwner)
        UpgradeableBeacon(implementation_, initialOwner)
    {}
}
