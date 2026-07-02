// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev 稳定币 / GB / B-Unit 换汇（外部 library，减轻 ConetTreasuryPeer bytecode）。
library ConetTreasuryPeerStableSwapLib {
    uint8 internal constant CANONICAL_GB_ERC20 = 1;
    uint8 internal constant CANONICAL_USDC_ERC20 = 2;
    uint8 internal constant CANONICAL_BUINT_ERC20 = 3;

    error InvalidCanonicalKind();
    error InvalidAmount();
    error RateNotSet();

    function isStableSwapKind(uint8 kind) public pure returns (bool) {
        return kind >= CANONICAL_GB_ERC20 && kind <= CANONICAL_BUINT_ERC20;
    }

    function quoteStableSwap(
        uint8 burnAssetKind,
        uint256 burnAmount,
        uint8 creditAssetKind,
        uint256 usdc6PerFullGb,
        uint256 usdcToBunitRate
    ) external pure returns (uint256) {
        if (!isStableSwapKind(burnAssetKind) || !isStableSwapKind(creditAssetKind)) revert InvalidCanonicalKind();
        if (burnAmount == 0) revert InvalidAmount();
        if (burnAssetKind == creditAssetKind) return burnAmount;

        if (burnAssetKind == CANONICAL_USDC_ERC20 && creditAssetKind == CANONICAL_BUINT_ERC20) {
            return burnAmount * usdcToBunitRate;
        }
        if (burnAssetKind == CANONICAL_BUINT_ERC20 && creditAssetKind == CANONICAL_USDC_ERC20) {
            return burnAmount / usdcToBunitRate;
        }
        if (burnAssetKind == CANONICAL_USDC_ERC20 && creditAssetKind == CANONICAL_GB_ERC20) {
            if (usdc6PerFullGb == 0) revert RateNotSet();
            return (burnAmount * 1e9) / usdc6PerFullGb;
        }
        if (burnAssetKind == CANONICAL_GB_ERC20 && creditAssetKind == CANONICAL_USDC_ERC20) {
            if (usdc6PerFullGb == 0) revert RateNotSet();
            return (burnAmount * usdc6PerFullGb) / 1e9;
        }
        if (burnAssetKind == CANONICAL_GB_ERC20 && creditAssetKind == CANONICAL_BUINT_ERC20) {
            if (usdc6PerFullGb == 0) revert RateNotSet();
            uint256 usdc6 = (burnAmount * usdc6PerFullGb) / 1e9;
            return usdc6 * usdcToBunitRate;
        }
        if (burnAssetKind == CANONICAL_BUINT_ERC20 && creditAssetKind == CANONICAL_GB_ERC20) {
            if (usdc6PerFullGb == 0) revert RateNotSet();
            uint256 usdc6 = burnAmount / usdcToBunitRate;
            return (usdc6 * 1e9) / usdc6PerFullGb;
        }
        revert InvalidCanonicalKind();
    }
}
