// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioContainerLayoutConstantsV07.sol";

/// @dev EIP-7201-style container module storage (delegatecall). Slot from `BeamioContainerLayoutConstantsV07`.
library BeamioContainerStorageV07 {
	bytes32 internal constant SLOT = BeamioContainerLayoutConstantsV07.SLOT;

	struct Redeem {
		bool active;
		bool used;
		uint64 expiry; // 0 => never
		address presetTo;
		bytes32 itemsHash;
		bytes itemsData; // abi.encode(ContainerItem[])
	}

	struct Pool {
		bool active;
		uint64 expiry;
		uint32 remaining;
		bytes32 itemsHash;
		bytes itemsData;
	}

	/// @dev status: 0 Pending, 1 ReserveApproved, 2 Completed, 3 Cancelled
	struct ReserveEntry {
		uint8 status;
		uint64 cancelDeadline;
		address beneficiary;
		bytes32 itemsHash;
		bytes itemsData;
	}

	struct Layout {
		uint256 relayedNonce;
		uint256 openRelayedNonce;
		mapping(address => uint256) reservedErc20;
		mapping(address => mapping(uint256 => uint256)) reserved1155;
		mapping(bytes32 => Redeem) redeems;
		mapping(bytes32 => Pool) pools;
		mapping(bytes32 => mapping(address => bool)) poolClaimed;
		mapping(address => uint256[]) reserveIdsByBeneficiary;
		mapping(uint256 => ReserveEntry) reserveById;
		uint256 nextReserveId;
	}

	function layout() internal pure returns (Layout storage l) {
		bytes32 slot = SLOT;
		assembly {
			l.slot := slot
		}
	}
}
