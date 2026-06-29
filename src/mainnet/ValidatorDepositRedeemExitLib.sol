// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ValidatorBinding} from "./ValidatorDepositRedeemTypes.sol";

/**
 * @title ValidatorDepositRedeemExitLib
 * @notice External library: full-exit principal payout (EIP-170 offload).
 */
library ValidatorDepositRedeemExitLib {
    event NativeWithdrawn(address indexed to, uint256 amount);
    event FullExitSettled(address indexed beneficiary, uint256 validatorCount, uint256 amount);

    function settleFullExitPayout(
        mapping(uint256 => address) storage guardianIdBeneficiary,
        mapping(uint256 => ValidatorBinding) storage nodeValidator,
        mapping(bytes32 => bool) storage exitSettledPubkey,
        mapping(address => uint256) storage stakedValidatorCountOf,
        uint256 validatorStakeWei,
        address beneficiary,
        uint256[] calldata guardianIds
    ) external returns (uint256 settledCount) {
        require(beneficiary != address(0), "ValidatorRedeem: zero beneficiary");
        require(guardianIds.length > 0, "ValidatorRedeem: empty");

        for (uint256 i = 0; i < guardianIds.length; i++) {
            uint256 guardianId = guardianIds[i];
            require(guardianIdBeneficiary[guardianId] == beneficiary, "ValidatorRedeem: not beneficiary node");
            ValidatorBinding storage b = nodeValidator[guardianId];
            require(b.pubkey.length != 0, "ValidatorRedeem: no validator");
            require(b.withdrawalBeneficiary == beneficiary, "ValidatorRedeem: beneficiary mismatch");
            require(b.exitedAt != 0, "ValidatorRedeem: exit not requested");
            bytes32 pkHash = keccak256(b.pubkey);
            require(!exitSettledPubkey[pkHash], "ValidatorRedeem: already settled");
            exitSettledPubkey[pkHash] = true;
            settledCount++;
        }

        uint256 amount = validatorStakeWei * settledCount;
        require(address(this).balance >= amount, "ValidatorRedeem: insufficient balance");

        if (stakedValidatorCountOf[beneficiary] >= settledCount) {
            stakedValidatorCountOf[beneficiary] -= settledCount;
        } else {
            stakedValidatorCountOf[beneficiary] = 0;
        }

        (bool ok, ) = payable(beneficiary).call{value: amount}("");
        require(ok, "ValidatorRedeem: native transfer failed");
        emit NativeWithdrawn(beneficiary, amount);
        emit FullExitSettled(beneficiary, settledCount, amount);
    }
}
