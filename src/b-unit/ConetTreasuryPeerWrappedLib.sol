// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FactoryERC20} from "./FactoryERC20.sol";

/// @dev 外部 library：FactoryERC20 CREATE2 部署逻辑，减轻 ConetTreasuryPeer bytecode。
library ConetTreasuryPeerWrappedLib {
    address internal constant NICK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error WrappedDeployFailed();
    error WrappedAddressMismatch();

    function wrappedSalt(uint256 peerChainId, address peerToken) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("beamio.wrapped.erc20.v1", peerChainId, peerToken));
    }

    function predictCreate2(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), NICK_CREATE2_FACTORY, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    function factoryInitCode(string memory name_, string memory symbol_, uint8 decimals_, address minter)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(type(FactoryERC20).creationCode, abi.encode(name_, symbol_, decimals_, minter));
    }

    function computeWrappedAddress(
        address minter,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 peerChainId,
        address peerToken
    ) public view returns (address) {
        bytes memory initCode = factoryInitCode(name_, symbol_, decimals_, minter);
        return predictCreate2(wrappedSalt(peerChainId, peerToken), keccak256(initCode));
    }

    function nickCreate2Deploy(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        deployed = predictCreate2(salt, keccak256(initCode));
        (bool ok,) = NICK_CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        if (!ok) revert WrappedDeployFailed();
        uint256 size;
        assembly {
            size := extcodesize(deployed)
        }
        if (size == 0) revert WrappedDeployFailed();
    }

    function ensureWrapped(
        address minter,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 peerChainId,
        address peerToken
    ) external returns (address wrapped) {
        wrapped = computeWrappedAddress(minter, name_, symbol_, decimals_, peerChainId, peerToken);
        uint256 size;
        assembly {
            size := extcodesize(wrapped)
        }
        if (size > 0) return wrapped;

        bytes memory initCode = factoryInitCode(name_, symbol_, decimals_, minter);
        bytes32 salt = wrappedSalt(peerChainId, peerToken);
        address deployed = nickCreate2Deploy(salt, initCode);
        if (deployed != wrapped) revert WrappedAddressMismatch();
        return wrapped;
    }
}
