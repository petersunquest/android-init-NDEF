// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Shared upgrade authorization for CoNET-DLE L1 MVP implementations.
/// @dev Implementations are locked; every proxy must be initialized atomically.
abstract contract DLEUpgradeableBase is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    error ZeroAddress();

    constructor() {
        _disableInitializers();
    }

    function __DLEUpgradeableBase_init(address initialOwner) internal onlyInitializing {
        if (initialOwner == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
