// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IDepositUnit} from "./IDepositUnit.sol";

/// @title DepositUnitFactory
/// @notice Derives one deposit unit per accepted deposit with CREATE2. Only the treasury that deployed it may call it.
/// @dev The salt binds the chain, the treasury, the derivation rules version, the token and the unique deposit identifier.
///      Anyone can therefore precompute a unit address from public data. The factory has no owner and no upgrade path.
///      A change of derivation rules requires a new factory and a new treasury.
contract DepositUnitFactory {
    /// @notice Version of the derivation rules, bound into every salt.
    uint256 public constant RULES_VERSION = 1;

    address public immutable TREASURY;
    address public immutable IMPLEMENTATION;

    event UnitCreated(bytes32 indexed depositId, address indexed token, address indexed unit);

    error NotTreasury();
    error ZeroAddress();

    constructor(address treasury_, address implementation_) {
        if (treasury_ == address(0) || implementation_ == address(0)) revert ZeroAddress();
        TREASURY = treasury_;
        IMPLEMENTATION = implementation_;
    }

    /// @notice Creates and binds the unit of one deposit. Called by the treasury in the same transaction as the deposit.
    function createUnit(bytes32 depositId, address token) external returns (address unit) {
        if (msg.sender != TREASURY) revert NotTreasury();
        unit = Clones.cloneDeterministic(IMPLEMENTATION, _salt(depositId, token));
        IDepositUnit(unit).initialize(TREASURY, token);
        emit UnitCreated(depositId, token, unit);
    }

    /// @notice The unit address that `createUnit` produces for this deposit, computed from public data alone.
    function predictUnit(bytes32 depositId, address token) external view returns (address) {
        return Clones.predictDeterministicAddress(IMPLEMENTATION, _salt(depositId, token), address(this));
    }

    function _salt(bytes32 depositId, address token) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, TREASURY, RULES_VERSION, token, depositId));
    }
}
