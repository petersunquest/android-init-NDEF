// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title BUnitAirdropV2TreasuryWire
 * @notice Temporary UUPS impl for live BUnitAirdrop proxy `0x305f…`.
 * @dev Storage layout matched from chain probe (2026-07):
 *      slot0 bunit, slot1 conetTreasury, slot2 conetUsdc.
 *      Ownable/UUPS use OZ namespaced storage (not colliding with slot0–2).
 *      Flow: upgradeToAndCall(this, set…) → upgrade back to production impl.
 */
contract BUnitAirdropV2TreasuryWire is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    address public bunit;
    address public conetTreasury;
    address public conetUsdc;

    /// @dev Absorb remaining production storage so accidental writes stay in gap.
    uint256[47] private __gap;

    event ConetTreasuryAndUsdcUpdated(address indexed treasury, address indexed usdc);

    constructor() {
        _disableInitializers();
    }

    function setConetTreasuryAndUsdc(address _conetTreasury, address _conetUsdc) external onlyOwner {
        conetTreasury = _conetTreasury;
        conetUsdc = _conetUsdc;
        emit ConetTreasuryAndUsdcUpdated(_conetTreasury, _conetUsdc);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
