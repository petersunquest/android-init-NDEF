// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IBeamioUserCardSelfDelegate.sol";

/// @dev Delegatecall modules inherit ERC1155 and must not call `_mint`/`_burn` directly:
///      that runs OZ `_update` without the card hook that maintains TotalSupplyStorage.
library BeamioUserCardModuleMintLib {
    function cardMint(address to, uint256 id, uint256 amount) internal {
        if (amount == 0) return;
        IBeamioUserCardSelfDelegate(address(this)).cardSelfMint(to, id, amount);
    }

    function cardBurn(address from, uint256 id, uint256 amount) internal {
        if (amount == 0) return;
        IBeamioUserCardSelfDelegate(address(this)).cardSelfBurn(from, id, amount);
    }
}
