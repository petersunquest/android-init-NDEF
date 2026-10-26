// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IUnitStateVerifier} from "../IUnitStateVerifier.sol";

/// @title UnitStateMockVerifier
/// @notice Test-only verifier. A proof is accepted only if the test registered those exact bytes for that message kind.
contract UnitStateMockVerifier is IUnitStateVerifier {
    error UnknownProof();

    mapping(bytes32 proofHash => bool) private _hasState;
    mapping(bytes32 proofHash => UnitState) private _state;
    mapping(bytes32 proofHash => bool) private _hasLoss;
    mapping(bytes32 proofHash => UnitLoss) private _loss;

    function registerUnitState(bytes calldata proof, UnitState calldata s) external {
        bytes32 k = keccak256(proof);
        _hasState[k] = true;
        _state[k] = s;
    }

    function registerUnitLoss(bytes calldata proof, UnitLoss calldata l) external {
        bytes32 k = keccak256(proof);
        _hasLoss[k] = true;
        _loss[k] = l;
    }

    function verifyUnitState(bytes calldata proof) external view returns (UnitState memory) {
        bytes32 k = keccak256(proof);
        if (!_hasState[k]) revert UnknownProof();
        return _state[k];
    }

    function verifyUnitLoss(bytes calldata proof) external view returns (UnitLoss memory) {
        bytes32 k = keccak256(proof);
        if (!_hasLoss[k]) revert UnknownProof();
        return _loss[k];
    }
}
