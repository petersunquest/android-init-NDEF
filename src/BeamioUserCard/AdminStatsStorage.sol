// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================================================
   AdminStatsStorage (delegatecall storage in card)
   Admin 维度 token #0 (points) mint 统计，与 Indexer 的 adminHourlyData/adminMintCounterByCard 语义一致。
   Card 自身即 card，故仅需 admin 维度：adminMintCounter[admin]、adminHourlyData[admin][hourIndex]。
   ========================================================= */

library AdminStatsStorage {
    bytes32 internal constant SLOT = keccak256("beamio.usercard.admin.stats.storage.v1");

    struct HourlyStats {
        uint256 nftMinted;
        uint256 tokenMinted;
        uint256 tokenBurned;
        uint256 transferCount;
        uint256 transferAmount;
        uint256 redeemMintAmount;
        uint256 usdcMintAmount;
        uint256 issuedCount;
        uint256 upgradedCount;
        bool hasData;
    }

    struct Layout {
        /// @dev admin  cumulative mint token 0，从上次 clear 起；parent admin 可清零 subordinate
        mapping(address => uint256) adminMintCounter;
        /// @dev admin  cumulative burn token 0，从上次 clear 起
        mapping(address => uint256) adminBurnCounter;
        /// @dev admin  cumulative transfer token 0 次数，从上次 clear 起
        mapping(address => uint256) adminTransferCounter;
        /// @dev admin  cumulative transfer token 0 金额，从上次 clear 起
        mapping(address => uint256) adminTransferAmountCounter;
        /// @dev admin redeem 完成后累计记入的 mint token 0（从上次 clear 起）
        mapping(address => uint256) adminRedeemMintCounter;
        /// @dev admin USDC topup 完成后累计记入的 mint token 0（从上次 clear 起）
        mapping(address => uint256) adminUSDCMintCounter;
        /// @dev admin 维度：token #0 (points) 的 mint/burn/transfer 统计，hourIndex = timestamp / 3600
        mapping(address => mapping(uint256 => HourlyStats)) adminHourlyData;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly { l.slot := slot }
    }

    function _upd(
        HourlyStats storage st,
        uint256 nft,
        uint256 mint,
        uint256 burn,
        uint256 trans,
        uint256 transferAmt,
        uint256 redeemMintAmt,
        uint256 usdcMintAmt,
        uint256 issued,
        uint256 upgraded
    ) internal {
        if (!st.hasData) st.hasData = true;
        st.nftMinted += nft;
        st.tokenMinted += mint;
        st.tokenBurned += burn;
        st.transferCount += trans;
        st.transferAmount += transferAmt;
        st.redeemMintAmount += redeemMintAmt;
        st.usdcMintAmount += usdcMintAmt;
        st.issuedCount += issued;
        st.upgradedCount += upgraded;
    }

    /// @dev 记录 admin mint，更新 cumulative 与 hourly
    function recordMint(address admin, uint256 amount) internal {
        if (admin == address(0) || amount == 0) return;
        Layout storage l = layout();
        l.adminMintCounter[admin] += amount;
        uint256 hourIndex = block.timestamp / 3600;
        _upd(l.adminHourlyData[admin][hourIndex], 0, amount, 0, 0, 0, 0, 0, 0, 0);
    }

    /// @dev 记录 admin burn，更新 hourly 与 adminBurnCounter
    function recordBurn(address admin, uint256 amount) internal {
        if (admin == address(0) || amount == 0) return;
        Layout storage l = layout();
        l.adminBurnCounter[admin] += amount;
        uint256 hourIndex = block.timestamp / 3600;
        _upd(l.adminHourlyData[admin][hourIndex], 0, 0, amount, 0, 0, 0, 0, 0, 0);
    }

    /// @dev 记录 admin transfer 次数与金额，更新 hourly、adminTransferCounter、adminTransferAmountCounter
    function recordTransfer(address admin, uint256 count, uint256 amount) internal {
        if (admin == address(0) || (count == 0 && amount == 0)) return;
        Layout storage l = layout();
        l.adminTransferCounter[admin] += count;
        l.adminTransferAmountCounter[admin] += amount;
        uint256 hourIndex = block.timestamp / 3600;
        _upd(l.adminHourlyData[admin][hourIndex], 0, 0, 0, count, amount, 0, 0, 0, 0);
    }

    /// @dev 记录 admin 发行新卡/upgrade 卡统计，仅更新 hourly
    function recordMembershipFlow(address admin, uint256 issued, uint256 upgraded) internal {
        if (admin == address(0) || (issued == 0 && upgraded == 0)) return;
        Layout storage l = layout();
        uint256 hourIndex = block.timestamp / 3600;
        _upd(l.adminHourlyData[admin][hourIndex], 0, 0, 0, 0, 0, 0, 0, issued, upgraded);
    }

    /// @dev 记录 admin redeem 完成后的单独 mint 计数，仅更新 cumulative counter
    function recordRedeemMint(address admin, uint256 amount) internal {
        if (admin == address(0) || amount == 0) return;
        Layout storage l = layout();
        l.adminRedeemMintCounter[admin] += amount;
        uint256 hourIndex = block.timestamp / 3600;
        _upd(l.adminHourlyData[admin][hourIndex], 0, 0, 0, 0, 0, amount, 0, 0, 0);
    }

    /// @dev 记录 admin USDC topup 完成后的单独 mint 计数，仅更新 cumulative counter
    function recordUSDCMint(address admin, uint256 amount) internal {
        if (admin == address(0) || amount == 0) return;
        Layout storage l = layout();
        l.adminUSDCMintCounter[admin] += amount;
        uint256 hourIndex = block.timestamp / 3600;
        _upd(l.adminHourlyData[admin][hourIndex], 0, 0, 0, 0, 0, 0, amount, 0, 0);
    }
}
