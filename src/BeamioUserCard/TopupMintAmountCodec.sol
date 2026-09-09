// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TopupMintAmountCodec
 * @notice Pack total (#0 mint) + paid (Reward PT #13 base) into one uint256 for
 *         Factory `mintPointsByAdmin(address,uint256)` (2-arg ABI cannot grow).
 *
 * Packed layout (bit 255 set):
 *   bits[0..127]   = totalPoints6  (#0 mint / membership / airdrop limit)
 *   bits[128..254] = paidPoints6   (实付 → #13 actor/referrer base)
 *   bit 255        = PACKED_FLAG
 *
 * Legacy (bit 255 clear): raw = total = paid (no promotion bonus split).
 *
 * Optional fallback when not packed but `promotionBonusRatioE6 > 0`:
 *   total ≈ paid * (1e6 + bonus) / 1e6  →  paid = total * 1e6 / (1e6 + bonus)
 */
library TopupMintAmountCodec {
    uint256 internal constant PACKED_FLAG = 1 << 255;
    uint256 internal constant MASK_128 = type(uint128).max;
    uint256 internal constant ONE_E6 = 1_000_000;

    error TopupMintPackOverflow();
    error TopupMintPackPaidExceedsTotal();
    error TopupMintPackZero();

    function isPacked(uint256 raw) internal pure returns (bool) {
        return (raw & PACKED_FLAG) != 0;
    }

    /// @notice Pack total + paid. Reverts if either exceeds uint128 or paid > total.
    function pack(uint256 totalPoints6, uint256 paidPoints6) internal pure returns (uint256) {
        if (totalPoints6 == 0 || paidPoints6 == 0) revert TopupMintPackZero();
        if (totalPoints6 > MASK_128 || paidPoints6 > MASK_128) revert TopupMintPackOverflow();
        if (paidPoints6 > totalPoints6) revert TopupMintPackPaidExceedsTotal();
        return PACKED_FLAG | (paidPoints6 << 128) | totalPoints6;
    }

    /// @notice Unpack; legacy raw returns (raw, raw).
    function unpack(uint256 raw) internal pure returns (uint256 totalPoints6, uint256 paidPoints6) {
        if (!isPacked(raw)) {
            return (raw, raw);
        }
        uint256 body = raw & ~PACKED_FLAG;
        totalPoints6 = body & MASK_128;
        paidPoints6 = body >> 128;
    }

    /**
     * @notice Resolve total + paid for #0 / #13.
     * @param raw mintPointsByAdmin amount (packed or legacy total)
     * @param promotionBonusRatioE6 optional on-chain Top-up Promotion % (E6); used only when not packed
     */
    function resolve(uint256 raw, uint256 promotionBonusRatioE6)
        internal
        pure
        returns (uint256 totalPoints6, uint256 paidPoints6)
    {
        if (isPacked(raw)) {
            return unpack(raw);
        }
        totalPoints6 = raw;
        if (promotionBonusRatioE6 == 0 || raw == 0) {
            return (raw, raw);
        }
        // total = paid * (1e6 + bonus) / 1e6  →  paid = total * 1e6 / (1e6 + bonus)
        uint256 denom = ONE_E6 + promotionBonusRatioE6;
        paidPoints6 = (raw * ONE_E6) / denom;
        if (paidPoints6 == 0) paidPoints6 = raw;
        if (paidPoints6 > totalPoints6) paidPoints6 = totalPoints6;
    }
}
