// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Storage base slot for `BeamioContainerStorageV07.Layout` (delegatecall into module).
///      MUST stay in sync with `BeamioContainerStorageV07.sol`.
library BeamioContainerLayoutConstantsV07 {
	bytes32 internal constant SLOT = keccak256("beamio.container.module.storage.v07");
}
