// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Per-line settlement sink (immutable target of LabLineMemberManagedExecutor).
contract LabPoolSink {
    event Received(address indexed from, uint256 amount);

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function balance() external view returns (uint256) {
        return address(this).balance;
    }
}
