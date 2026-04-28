// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice AA-only entry: forwards to BeamioUserCard.mintPointsOpenContainerRelay (executor must match factory config).
interface IBeamioFactoryPaymasterIsAccount {
	function isBeamioAccount(address account) external view returns (bool);
}

interface IUserCardMintOpenRelay {
	function mintPointsOpenContainerRelay(address payerAA, uint256 points6, address operator) external;
}

/// @dev Deploy with BeamioFactoryPaymasterV07 address; admin sets same address on factory via setOpenContainerMintExecutor.
contract BeamioOpenContainerMintExecutor {
	address public immutable beamioFactory;

	constructor(address beamioFactory_) {
		require(beamioFactory_ != address(0), "zero factory");
		beamioFactory = beamioFactory_;
	}

	function mintPointsForOpen(address userCard, uint256 points6, address operator) external {
		require(IBeamioFactoryPaymasterIsAccount(beamioFactory).isBeamioAccount(msg.sender), "not aa");
		IUserCardMintOpenRelay(userCard).mintPointsOpenContainerRelay(msg.sender, points6, operator);
	}
}
