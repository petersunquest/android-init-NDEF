// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Stable-address proxy used by every stateful CoNET-DLE MVP component.
contract DLEERC1967Proxy is ERC1967Proxy {
    constructor(address implementation, bytes memory initialization)
        ERC1967Proxy(implementation, initialization)
    {}
}
