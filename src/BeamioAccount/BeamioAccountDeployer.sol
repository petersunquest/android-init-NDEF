// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Deprecated — AA creation uses Nick CREATE2 via `BeamioAccountCreate2Lib` in `BeamioFactoryPaymasterV07`.
///      Kept for historical artifact / verification only; do not deploy or reference in new scripts.
contract BeamioAccountDeployer {
    address public factory;

    event FactorySet(address indexed oldFactory, address indexed newFactory);
    event Deployed(address indexed addr, bytes32 indexed salt, bytes32 initCodeHash);

    modifier onlyFactory() {
        require(msg.sender == factory, "only factory");
        _;
    }

    function setFactory(address f) external {
        require(factory == address(0), "factory already set");
        require(f != address(0) && f.code.length > 0, "bad factory");
        emit FactorySet(address(0), f);
        factory = f;
    }

    // ✅ 单一账户：salt 不含 kind
    function computeSalt(address creator, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode(creator, index));
    }

    function getAddress(bytes32 salt, bytes calldata initCode) public view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initCode))
        );
        return address(uint160(uint256(hash)));
    }

    function deploy(bytes32 salt, bytes calldata initCode) external onlyFactory returns (address addr) {
        require(initCode.length != 0, "empty initCode");
        assembly {
            let ptr := mload(0x40)
            let len := initCode.length
            calldatacopy(ptr, initCode.offset, len)
            addr := create2(0, ptr, len, salt)
        }
        require(addr != address(0) && addr.code.length > 0, "deploy failed");
        emit Deployed(addr, salt, keccak256(initCode));
    }
}
