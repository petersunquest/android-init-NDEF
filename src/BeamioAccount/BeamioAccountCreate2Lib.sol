// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Nick CREATE2 辅助库（internal 内联，无需单独 link/deploy）。
 */
library BeamioAccountCreate2Lib {
    address internal constant NICK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error LibDeployFailed();

    function predict(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), NICK_CREATE2_FACTORY, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    function nickDeploy(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        deployed = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), NICK_CREATE2_FACTORY, salt, keccak256(initCode)))
                )
            )
        );
        (bool ok,) = NICK_CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        if (!ok) revert LibDeployFailed();
        uint256 size;
        assembly {
            size := extcodesize(deployed)
        }
        if (size == 0) revert LibDeployFailed();
    }
}
