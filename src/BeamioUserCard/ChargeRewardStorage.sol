// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ChargeRewardStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.charge.reward.storage.v1");

    struct Layout {
        /// @dev E6 比例：1_000_000 = 1:1；0 = 关闭 — Charge actor mint #13
        uint256 chargeRewardRatioE6;
        /// @dev E6 比例：Top-up **实付** amountFiat6 → actor #13；0 = 关闭（与 referrer topup ratio 对称）
        uint256 topupActorRewardRatioE6;
        /// @dev Top-up Promotion bonus % (E6). Legacy unpack only when mint amount is NOT packed
        ///      (bit255 clear): paid = total * 1e6 / (1e6 + bonus). Fixed-amount promotions
        ///      must pack paid|total via TopupMintAmountCodec. Append-only slot (do not reorder).
        uint256 topupPromotionBonusRatioE6;
        /// @dev Enable flag for #13→#0: 0 = closed; >0 = on. Mint uses card currency 1:1 via
        ///      pointsUnitPriceInCurrencyE6 (minted0 = burn13 * 1e6 / price). Prefer 1_000_000.
        uint256 convertReward13ToPointsRatioE6;
        /// @dev Enable flag for #13→USDC: 0 = closed; >0 = on. Payout uses Factory oracle
        ///      quoteCurrencyAmountInUSDC6(currency, burn13) then withdraw spread. Prefer 1_000_000.
        uint256 convertReward13ToUsdcRatioE6;
        /// @dev Merchant-favorable oracle spread in bps (0–1000 = 0%–10%). Single truth for
        ///      USDC top-up / USDC charge / USDC coupon·catalog purchase / #13→USDC withdraw.
        ///      Deposit: user pays fairUsdc * 10000 / (10000 - s) (or receives fewer fiat units).
        ///      Withdraw: user receives fairUsdc * (10000 - s) / 10000.
        uint256 merchantOracleSpreadBps;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
