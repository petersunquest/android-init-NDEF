// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CoNETIncomePeriodLib} from "../b-unit/CoNETIncomePeriodLib.sol";

/**
 * @title ValidatorDepositRedeemRewardLib
 * @notice External library: CL skim reward payout via {settleNodeRewards}. Linked from {ValidatorDepositRedeem}
 *         to keep the UUPS implementation within EIP-170.
 */
library ValidatorDepositRedeemRewardLib {
    uint256 internal constant VALIDATOR_STAKE_WEI = 32 ether;

    event NodeRewardSettled(
        uint256 indexed guardianId,
        address indexed beneficiary,
        uint256 amount,
        bytes32 indexed eventKey
    );

    function settleNodeRewards(
        mapping(bytes32 => bool) storage consumedRewardEventKey,
        mapping(address => uint256) storage clRewardPaid,
        mapping(address => mapping(uint256 => uint256)) storage beneficiaryClHourly,
        mapping(address => mapping(uint8 => mapping(uint256 => uint256))) storage beneficiaryClPeriod,
        mapping(uint256 => address) storage guardianIdBeneficiary,
        uint256 totalStakedValidatorCount,
        uint256[] calldata guardianIds,
        uint256[] calldata amounts,
        bytes32[] calldata eventKeys
    ) external returns (uint256 batchPaid) {
        uint256 n = guardianIds.length;
        require(n > 0, "ValidatorRedeem: empty");
        require(amounts.length == n && eventKeys.length == n, "ValidatorRedeem: length mismatch");

        uint256 principalReserve = VALIDATOR_STAKE_WEI * totalStakedValidatorCount;

        for (uint256 i = 0; i < n; i++) {
            bytes32 key = eventKeys[i];
            require(key != bytes32(0), "ValidatorRedeem: zero eventKey");
            if (consumedRewardEventKey[key]) continue;

            uint256 amount = amounts[i];
            if (amount == 0) {
                consumedRewardEventKey[key] = true;
                continue;
            }

            uint256 guardianId = guardianIds[i];
            address beneficiary = guardianIdBeneficiary[guardianId];
            require(beneficiary != address(0), "ValidatorRedeem: no beneficiary");

            require(address(this).balance >= amount, "ValidatorRedeem: insufficient balance");
            require(
                address(this).balance - amount >= principalReserve,
                "ValidatorRedeem: would touch principal reserve"
            );

            consumedRewardEventKey[key] = true;
            clRewardPaid[beneficiary] += amount;
            CoNETIncomePeriodLib.accumulate(
                beneficiaryClHourly[beneficiary], beneficiaryClPeriod[beneficiary], block.timestamp, amount
            );
            batchPaid += amount;

            (bool ok, ) = payable(beneficiary).call{value: amount}("");
            require(ok, "ValidatorRedeem: native transfer failed");
            emit NodeRewardSettled(guardianId, beneficiary, amount, key);
        }
    }
}
