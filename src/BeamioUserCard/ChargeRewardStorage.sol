// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ChargeRewardStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.charge.reward.storage.v1");

    struct Layout {
        /// @dev E6 比例：1_000_000 = 1:1；0 = 关闭
        uint256 chargeRewardRatioE6;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
