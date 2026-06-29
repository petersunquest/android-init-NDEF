// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ValidatorBinding} from "./ValidatorDepositRedeemTypes.sol";

interface IBeaconDepositFund {
    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) external payable;
}

/**
 * @title ValidatorDepositRedeemDepositLib
 * @notice External library: fund + deposit validators and register bindings (EIP-170 offload).
 */
library ValidatorDepositRedeemDepositLib {
    event ValidatorDeposited(
        uint256 indexed guardianId,
        address indexed beneficiary,
        bytes32 indexed pubkeyHash,
        uint256 amount
    );
    event NodeValidatorRegistered(
        uint256 indexed guardianId,
        address indexed beneficiary,
        bytes32 indexed pubkeyHash,
        bytes pubkey
    );

    function fundAndDepositValidators(
        address depositContractAddr,
        bytes32 selfCred,
        uint256 validatorStakeWei,
        mapping(uint256 => address) storage guardianIdBeneficiary,
        mapping(uint256 => ValidatorBinding) storage nodeValidator,
        mapping(bytes32 => uint256) storage validatorPubkeyGuardian,
        mapping(address => uint256) storage stakedValidatorCountOf,
        uint256[] calldata guardianIds,
        bytes[] calldata pubkeys,
        bytes[] calldata withdrawalCredentials,
        bytes[] calldata signatures,
        bytes32[] calldata depositDataRoots
    ) external returns (uint256 stakedCountDelta, uint256 fundedDelta) {
        uint256 n = guardianIds.length;
        require(n > 0, "ValidatorRedeem: empty");
        require(
            pubkeys.length == n &&
            withdrawalCredentials.length == n &&
            signatures.length == n &&
            depositDataRoots.length == n,
            "ValidatorRedeem: length mismatch"
        );
        require(depositContractAddr != address(0), "ValidatorRedeem: deposit unset");
        IBeaconDepositFund depositContract = IBeaconDepositFund(depositContractAddr);
        require(address(this).balance >= validatorStakeWei * n, "ValidatorRedeem: insufficient stake balance");

        for (uint256 i = 0; i < n; i++) {
            require(withdrawalCredentials[i].length == 32, "ValidatorRedeem: bad wc length");
            require(_bytes32FromCalldata(withdrawalCredentials[i]) == selfCred, "ValidatorRedeem: withdrawal not self");

            uint256 guardianId = guardianIds[i];
            address beneficiary = guardianIdBeneficiary[guardianId];
            require(beneficiary != address(0), "ValidatorRedeem: node has no beneficiary");

            depositContract.deposit{value: validatorStakeWei}(
                pubkeys[i],
                withdrawalCredentials[i],
                signatures[i],
                depositDataRoots[i]
            );

            _registerOneNodeValidator(
                nodeValidator,
                validatorPubkeyGuardian,
                guardianId,
                beneficiary,
                pubkeys[i]
            );
            stakedValidatorCountOf[beneficiary] += 1;
            stakedCountDelta += 1;
            fundedDelta += validatorStakeWei;
            emit ValidatorDeposited(guardianId, beneficiary, keccak256(pubkeys[i]), validatorStakeWei);
        }
    }

    function _registerOneNodeValidator(
        mapping(uint256 => ValidatorBinding) storage nodeValidator,
        mapping(bytes32 => uint256) storage validatorPubkeyGuardian,
        uint256 guardianId,
        address beneficiary,
        bytes calldata pubkey
    ) private {
        require(guardianId != 0, "ValidatorRedeem: zero guardian id");
        require(pubkey.length == 48, "ValidatorRedeem: bad pubkey len");
        bytes32 pkHash = keccak256(pubkey);
        uint256 boundId = validatorPubkeyGuardian[pkHash];
        require(boundId == 0 || boundId == guardianId, "ValidatorRedeem: pubkey bound elsewhere");
        ValidatorBinding storage b = nodeValidator[guardianId];
        require(!b.active || keccak256(b.pubkey) == pkHash, "ValidatorRedeem: node already has active validator");

        b.pubkey = pubkey;
        b.withdrawalBeneficiary = beneficiary;
        b.registeredAt = uint64(block.timestamp);
        b.exitedAt = 0;
        b.active = true;
        validatorPubkeyGuardian[pkHash] = guardianId;

        emit NodeValidatorRegistered(guardianId, beneficiary, pkHash, pubkey);
    }

    function registerOneNodeValidator(
        mapping(uint256 => ValidatorBinding) storage nodeValidator,
        mapping(bytes32 => uint256) storage validatorPubkeyGuardian,
        uint256 guardianId,
        address beneficiary,
        bytes calldata pubkey
    ) external {
        _registerOneNodeValidator(nodeValidator, validatorPubkeyGuardian, guardianId, beneficiary, pubkey);
    }

    function _bytes32FromCalldata(bytes calldata b) private pure returns (bytes32 word) {
        require(b.length == 32, "ValidatorRedeem: bad wc length");
        assembly {
            word := calldataload(b.offset)
        }
    }
}
