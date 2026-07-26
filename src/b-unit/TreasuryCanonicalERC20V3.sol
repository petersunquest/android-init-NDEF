// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title TreasuryCanonicalERC20V3
/// @notice Canonical bridge token controlled by exactly one TreasuryBridgeV3.
contract TreasuryCanonicalERC20V3 is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    uint8 private _tokenDecimals;
    string public contractURI;

    error InvalidAddress();
    error InvalidMetadata();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        address admin_,
        address bridge_,
        string calldata contractURI_
    ) external initializer {
        if (admin_ == address(0) || bridge_ == address(0)) revert InvalidAddress();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert InvalidMetadata();
        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _tokenDecimals = decimals_;
        contractURI = contractURI_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(BRIDGE_ROLE, bridge_);
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _burn(account, amount);
    }

    function setBridge(address bridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bridge_ == address(0)) revert InvalidAddress();
        _grantRole(BRIDGE_ROLE, bridge_);
    }

    function revokeBridge(address bridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(BRIDGE_ROLE, bridge_);
    }

    function setContractURI(string calldata contractURI_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        contractURI = contractURI_;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}

    uint256[45] private __gap;
}
