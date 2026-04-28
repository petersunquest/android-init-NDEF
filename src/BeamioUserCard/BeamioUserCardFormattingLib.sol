// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev External library: ERC-1155 uri() 拼接与 hex 格式化移出主合约以降低 EIP-170 bytecode。
library BeamioUserCardFormattingLib {
    /// @notice `base` + `0x` + 40 hex chars of `self` + `"{id}.json"`（与主合约 uri() 约定一致）
    function buildErc1155MetadataUri(string memory base, address self) external pure returns (string memory) {
        return string(abi.encodePacked(base, _addressToHex40(self), "{id}.json"));
    }

    function addressToHex40(address a) external pure returns (string memory) {
        return _addressToHex40(a);
    }

    function _addressToHex40(address a) private pure returns (string memory) {
        bytes memory b = abi.encodePacked(a);
        bytes memory h = "0123456789abcdef";
        bytes memory r = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            r[i * 2] = h[uint8(b[i]) >> 4];
            r[i * 2 + 1] = h[uint8(b[i]) & 0x0f];
        }
        return string(r);
    }
}
