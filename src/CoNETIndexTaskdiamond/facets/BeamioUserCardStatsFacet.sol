// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibActionStorage} from "../libraries/LibActionStorage.sol";

contract BeamioUserCardStatsFacet {
    uint8 internal constant PERIOD_HOUR = 0;
    uint8 internal constant PERIOD_DAY = 1;
    uint8 internal constant PERIOD_WEEK = 2;
    uint8 internal constant PERIOD_MONTH = 3;
    uint8 internal constant PERIOD_QUARTER = 4;
    uint8 internal constant PERIOD_YEAR = 5;

    uint8 internal constant ACCOUNT_MODE_ALL = 0;
    uint8 internal constant ACCOUNT_MODE_EOA = 1;
    uint8 internal constant ACCOUNT_MODE_AA = 2;
    uint256 internal constant CHAIN_ID_FILTER_ALL = type(uint256).max;

    struct TransactionFull {
        bytes32 id;
        bytes32 originalPaymentHash;
        uint256 chainId;
        bytes32 txCategory;
        string displayJson;
        uint64 timestamp;
        address payer;
        address payee;
        uint256 finalRequestAmountFiat6;
        uint256 finalRequestAmountUSDC6;
        bool isAAAccount;
        address topAdmin;
        address subordinate;
        LibActionStorage.RouteItem[] route;
        LibActionStorage.FeeInfo fees;
        LibActionStorage.TransactionMeta meta;
    }

    struct MintStats {
        uint256 mintTxTotal;
        uint256 mintWalletCount;
        uint256 periodStart;
        uint256 periodEnd;
    }

    function getBeamioUserCardTokenHolderCount(address beamioUserCard, uint256 tokenId) external view returns (uint256) {
        require(beamioUserCard != address(0), "card=0");
        return LibActionStorage.layout().indexedHolderCountByAssetToken[beamioUserCard][tokenId];
    }

    function getBeamioUserCardNft0HolderCount(address beamioUserCard) external view returns (uint256) {
        require(beamioUserCard != address(0), "card=0");
        return LibActionStorage.layout().indexedHolderCountByAssetToken[beamioUserCard][0];
    }

    function getBeamioUserCardTokenIndexedBalance(
        address beamioUserCard,
        uint256 tokenId,
        address account
    ) external view returns (uint256) {
        require(beamioUserCard != address(0), "card=0");
        require(account != address(0), "account=0");
        return LibActionStorage.layout().indexedBalanceByAssetTokenAccount[beamioUserCard][tokenId][account];
    }

    /**
     * @notice 查询某时间窗口末状态下，某卡某 tokenId 的前 N 持币地址（严格小时快照口径）
     */
    function getBeamioUserCardTokenTopHoldersByCurrentPeriodOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint8 periodType,
        uint256 periodOffset,
        uint256 topN
    )
        external
        view
        returns (uint256 periodStart, uint256 periodEnd, address[] memory holders, uint256[] memory balancesE6)
    {
        require(beamioUserCard != address(0), "card=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        if (topN == 0) return (0, 0, new address[](0), new uint256[](0));

        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);

        uint64 endHour = uint64(periodEnd / 3600);
        (holders, balancesE6) = _topHoldersAtHour(beamioUserCard, tokenId, endHour, topN);
    }

    function getBeamioUserCardTokenTopHoldersByWeekOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        uint256 topN
    )
        external
        view
        returns (uint256 periodStart, uint256 periodEnd, address[] memory holders, uint256[] memory balancesE6)
    {
        return this.getBeamioUserCardTokenTopHoldersByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_WEEK,
            periodOffset,
            topN
        );
    }

    function getBeamioUserCardTokenTopHoldersByHourOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        uint256 topN
    )
        external
        view
        returns (uint256 periodStart, uint256 periodEnd, address[] memory holders, uint256[] memory balancesE6)
    {
        return this.getBeamioUserCardTokenTopHoldersByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_HOUR,
            periodOffset,
            topN
        );
    }

    function getBeamioUserCardTokenTopHoldersByDayOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        uint256 topN
    )
        external
        view
        returns (uint256 periodStart, uint256 periodEnd, address[] memory holders, uint256[] memory balancesE6)
    {
        return this.getBeamioUserCardTokenTopHoldersByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_DAY,
            periodOffset,
            topN
        );
    }

    function getBeamioUserCardTokenTopHoldersByMonthOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        uint256 topN
    )
        external
        view
        returns (uint256 periodStart, uint256 periodEnd, address[] memory holders, uint256[] memory balancesE6)
    {
        return this.getBeamioUserCardTokenTopHoldersByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_MONTH,
            periodOffset,
            topN
        );
    }

    function getBeamioUserCardTokenTopHoldersByQuarterOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        uint256 topN
    )
        external
        view
        returns (uint256 periodStart, uint256 periodEnd, address[] memory holders, uint256[] memory balancesE6)
    {
        return this.getBeamioUserCardTokenTopHoldersByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_QUARTER,
            periodOffset,
            topN
        );
    }

    function getBeamioUserCardTokenTopHoldersByYearOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        uint256 topN
    )
        external
        view
        returns (uint256 periodStart, uint256 periodEnd, address[] memory holders, uint256[] memory balancesE6)
    {
        return this.getBeamioUserCardTokenTopHoldersByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_YEAR,
            periodOffset,
            topN
        );
    }

    function getAssetActionCount(address asset) external view returns (uint256) {
        return LibActionStorage.layout().assetActionIds[asset].length;
    }

    function getAssetActionIdsPaged(address asset, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page)
    {
        uint256[] storage ids = LibActionStorage.layout().assetActionIds[asset];
        uint256 total = ids.length;
        if (offset >= total || limit == 0) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new uint256[](end - offset);
        for (uint256 i = 0; i < page.length; i++) page[i] = ids[offset + i];
    }

    function getAssetTransactionsPaged(address asset, uint256 offset, uint256 limit)
        external
        view
        returns (LibActionStorage.TransactionRecord[] memory page)
    {
        uint256[] storage ids = LibActionStorage.layout().assetActionIds[asset];
        uint256 total = ids.length;
        if (offset >= total || limit == 0) return new LibActionStorage.TransactionRecord[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        page = new LibActionStorage.TransactionRecord[](end - offset);
        for (uint256 i = 0; i < page.length; i++) page[i] = a.txRecordByActionId[ids[offset + i]];
    }

    function getAssetTokenActionCount(address asset, uint256 tokenId) external view returns (uint256) {
        return LibActionStorage.layout().assetTokenActionIds[asset][tokenId].length;
    }

    function getAssetTokenActionIdsPaged(address asset, uint256 tokenId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page)
    {
        uint256[] storage ids = LibActionStorage.layout().assetTokenActionIds[asset][tokenId];
        uint256 total = ids.length;
        if (offset >= total || limit == 0) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new uint256[](end - offset);
        for (uint256 i = 0; i < page.length; i++) page[i] = ids[offset + i];
    }

    function getAssetTokenTransactionsPaged(address asset, uint256 tokenId, uint256 offset, uint256 limit)
        external
        view
        returns (LibActionStorage.TransactionRecord[] memory page)
    {
        uint256[] storage ids = LibActionStorage.layout().assetTokenActionIds[asset][tokenId];
        uint256 total = ids.length;
        if (offset >= total || limit == 0) return new LibActionStorage.TransactionRecord[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        page = new LibActionStorage.TransactionRecord[](end - offset);
        for (uint256 i = 0; i < page.length; i++) page[i] = a.txRecordByActionId[ids[offset + i]];
    }

    function getAssetTransactionsByCurrentPeriodOffsetAndAccountModePaged(
        address asset,
        address account,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        require(asset != address(0), "asset=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        (total, page) = _getAssetTransactionsByRangePaged(
            asset, account, periodStart, periodEnd, pageOffset, pageLimit, txCategoryFilter, accountMode, chainIdFilter
        );
    }

    function getAssetTransactionsByCurrentPeriodOffsetAndAccountModePagedFull(
        address asset,
        address account,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, TransactionFull[] memory page)
    {
        require(asset != address(0), "asset=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        (total, page) = _getAssetTransactionsByRangePagedFull(
            asset, account, periodStart, periodEnd, pageOffset, pageLimit, txCategoryFilter, accountMode, chainIdFilter
        );
    }

    /**
     * @notice 按 asset + topAdmin 查询交易（周期分页 + EOA/AA 过滤）
     */
    function getAssetTransactionsByTopAdminAndCurrentPeriodOffsetAndAccountModePaged(
        address asset,
        address topAdmin,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        require(asset != address(0), "asset=0");
        require(topAdmin != address(0), "topAdmin=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        (total, page) = _getAssetTransactionsByTopAdminRangePaged(
            asset, topAdmin, periodStart, periodEnd, pageOffset, pageLimit, txCategoryFilter, accountMode, chainIdFilter
        );
    }

    function getAssetTransactionsByTopAdminAndCurrentPeriodOffsetAndAccountModePagedFull(
        address asset,
        address topAdmin,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, TransactionFull[] memory page)
    {
        require(asset != address(0), "asset=0");
        require(topAdmin != address(0), "topAdmin=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        (total, page) = _getAssetTransactionsByTopAdminRangePagedFull(
            asset, topAdmin, periodStart, periodEnd, pageOffset, pageLimit, txCategoryFilter, accountMode, chainIdFilter
        );
    }

    /**
     * @notice 按 asset + subordinate 查询交易（周期分页 + EOA/AA 过滤）
     */
    function getAssetTransactionsBySubordinateAndCurrentPeriodOffsetAndAccountModePaged(
        address asset,
        address subordinate,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        require(asset != address(0), "asset=0");
        require(subordinate != address(0), "subordinate=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        (total, page) = _getAssetTransactionsBySubordinateRangePaged(
            asset, subordinate, periodStart, periodEnd, pageOffset, pageLimit, txCategoryFilter, accountMode, chainIdFilter
        );
    }

    function getAssetTransactionsBySubordinateAndCurrentPeriodOffsetAndAccountModePagedFull(
        address asset,
        address subordinate,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, TransactionFull[] memory page)
    {
        require(asset != address(0), "asset=0");
        require(subordinate != address(0), "subordinate=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        (total, page) = _getAssetTransactionsBySubordinateRangePagedFull(
            asset, subordinate, periodStart, periodEnd, pageOffset, pageLimit, txCategoryFilter, accountMode, chainIdFilter
        );
    }

    function getAssetTokenTransactionsByCurrentPeriodOffsetAndAccountModePaged(
        address asset,
        uint256 tokenId,
        address account,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        require(asset != address(0), "asset=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        (total, page) = _getAssetTokenTransactionsByRangePaged(
            asset, tokenId, account, periodStart, periodEnd, pageOffset, pageLimit, txCategoryFilter, accountMode, chainIdFilter
        );
    }

    function getAssetTokenTransactionsByCurrentPeriodOffsetAndAccountModePagedFull(
        address asset,
        uint256 tokenId,
        address account,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, TransactionFull[] memory page)
    {
        require(asset != address(0), "asset=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        (total, page) = _getAssetTokenTransactionsByRangePagedFull(
            asset, tokenId, account, periodStart, periodEnd, pageOffset, pageLimit, txCategoryFilter, accountMode, chainIdFilter
        );
    }

    // BeamioUserCard convenience
    function getBeamioUserCardTransactionsByWeekOffsetAndAccountModePaged(
        address beamioUserCard,
        address account,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAssetTransactionsByCurrentPeriodOffsetAndAccountModePaged(
            beamioUserCard,
            account,
            PERIOD_WEEK,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTransactionsByTopAdminAndWeekOffsetAndAccountModePaged(
        address beamioUserCard,
        address topAdmin,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAssetTransactionsByTopAdminAndCurrentPeriodOffsetAndAccountModePaged(
            beamioUserCard,
            topAdmin,
            PERIOD_WEEK,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTransactionsBySubordinateAndWeekOffsetAndAccountModePaged(
        address beamioUserCard,
        address subordinate,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAssetTransactionsBySubordinateAndCurrentPeriodOffsetAndAccountModePaged(
            beamioUserCard,
            subordinate,
            PERIOD_WEEK,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTokenTransactionsByWeekOffsetAndAccountModePaged(
        address beamioUserCard,
        uint256 tokenId,
        address account,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAssetTokenTransactionsByCurrentPeriodOffsetAndAccountModePaged(
            beamioUserCard,
            tokenId,
            account,
            PERIOD_WEEK,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTransactionStatsByCurrentPeriodOffset(
        address beamioUserCard,
        uint8 periodType,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        require(beamioUserCard != address(0), "card=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        total = _countAssetTransactionsByRange(beamioUserCard, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter);
    }

    function getBeamioUserCardTransactionStatsByTopAdminAndCurrentPeriodOffset(
        address beamioUserCard,
        address topAdmin,
        uint8 periodType,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        require(beamioUserCard != address(0), "card=0");
        require(topAdmin != address(0), "topAdmin=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        total = _countAssetTransactionsByTopAdminRange(beamioUserCard, topAdmin, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter);
    }

    function getBeamioUserCardTransactionStatsBySubordinateAndCurrentPeriodOffset(
        address beamioUserCard,
        address subordinate,
        uint8 periodType,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        require(beamioUserCard != address(0), "card=0");
        require(subordinate != address(0), "subordinate=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);
        total = _countAssetTransactionsBySubordinateRange(beamioUserCard, subordinate, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter);
    }

    /**
     * @notice 统计某张 BeamioUserCard 在周期窗口内的 mint 总数与 mint 钱包地址数
     * @dev mint 钱包地址数按 payee 去重口径统计；mintTxCategoryFilter 必须传具体 mint 分类键
     */
    function getBeamioUserCardMintStatsByCurrentPeriodOffset(
        address beamioUserCard,
        uint8 periodType,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        require(beamioUserCard != address(0), "card=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        require(mintTxCategoryFilter != bytes32(0), "mintCategory=0");

        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        out.periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        out.periodEnd = _periodEndFromStart(out.periodStart, periodType);
        (out.mintTxTotal, out.mintWalletCount) = _countBeamioUserCardMintStatsByRange(
            beamioUserCard,
            out.periodStart,
            out.periodEnd,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardMintStatsByHourOffset(
        address beamioUserCard,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            PERIOD_HOUR,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardMintStatsByDayOffset(
        address beamioUserCard,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            PERIOD_DAY,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardMintStatsByWeekOffset(
        address beamioUserCard,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            PERIOD_WEEK,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardMintStatsByMonthOffset(
        address beamioUserCard,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            PERIOD_MONTH,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardMintStatsByQuarterOffset(
        address beamioUserCard,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            PERIOD_QUARTER,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardMintStatsByYearOffset(
        address beamioUserCard,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            PERIOD_YEAR,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    /**
     * @notice 统计某张 BeamioUserCard 在周期窗口内、指定 tokenId 的 mint 总数与 mint 钱包地址数
     * @dev mint 钱包地址数按 payee 去重口径统计；mintTxCategoryFilter 必须传具体 mint 分类键
     */
    function getBeamioUserCardTokenMintStatsByCurrentPeriodOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint8 periodType,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        require(beamioUserCard != address(0), "card=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        require(mintTxCategoryFilter != bytes32(0), "mintCategory=0");

        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        out.periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        out.periodEnd = _periodEndFromStart(out.periodStart, periodType);
        (out.mintTxTotal, out.mintWalletCount) = _countBeamioUserCardTokenMintStatsByRange(
            beamioUserCard,
            tokenId,
            out.periodStart,
            out.periodEnd,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTokenMintStatsByHourOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardTokenMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_HOUR,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTokenMintStatsByDayOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardTokenMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_DAY,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTokenMintStatsByWeekOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardTokenMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_WEEK,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTokenMintStatsByMonthOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardTokenMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_MONTH,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTokenMintStatsByQuarterOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardTokenMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_QUARTER,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardTokenMintStatsByYearOffset(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodOffset,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (MintStats memory out) {
        return this.getBeamioUserCardTokenMintStatsByCurrentPeriodOffset(
            beamioUserCard,
            tokenId,
            PERIOD_YEAR,
            periodOffset,
            mintTxCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    /**
     * @notice 统计某账号在某周期内、某资产（如 BeamioUserCard）的转账总数
     */
    function getAssetAccountTxCountByCurrentPeriodOffset(
        address asset,
        address account,
        uint8 periodType,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        require(asset != address(0), "asset=0");
        require(account != address(0), "account=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");

        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);

        total = _countAssetAccountTransactionsByRange(
            asset,
            account,
            periodStart,
            periodEnd,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    /**
     * @notice 统计某账号在某周期内、某张 BeamioUserCard 的转账总数
     */
    function getBeamioUserCardAccountTxCountByCurrentPeriodOffset(
        address beamioUserCard,
        address account,
        uint8 periodType,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        return this.getAssetAccountTxCountByCurrentPeriodOffset(
            beamioUserCard,
            account,
            periodType,
            periodOffset,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardAccountTxCountByHourOffset(
        address beamioUserCard,
        address account,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        return this.getBeamioUserCardAccountTxCountByCurrentPeriodOffset(
            beamioUserCard,
            account,
            PERIOD_HOUR,
            periodOffset,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardAccountTxCountByDayOffset(
        address beamioUserCard,
        address account,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        return this.getBeamioUserCardAccountTxCountByCurrentPeriodOffset(
            beamioUserCard,
            account,
            PERIOD_DAY,
            periodOffset,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardAccountTxCountByWeekOffset(
        address beamioUserCard,
        address account,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        return this.getBeamioUserCardAccountTxCountByCurrentPeriodOffset(
            beamioUserCard,
            account,
            PERIOD_WEEK,
            periodOffset,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardAccountTxCountByMonthOffset(
        address beamioUserCard,
        address account,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        return this.getBeamioUserCardAccountTxCountByCurrentPeriodOffset(
            beamioUserCard,
            account,
            PERIOD_MONTH,
            periodOffset,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardAccountTxCountByQuarterOffset(
        address beamioUserCard,
        address account,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        return this.getBeamioUserCardAccountTxCountByCurrentPeriodOffset(
            beamioUserCard,
            account,
            PERIOD_QUARTER,
            periodOffset,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function getBeamioUserCardAccountTxCountByYearOffset(
        address beamioUserCard,
        address account,
        uint256 periodOffset,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd) {
        return this.getBeamioUserCardAccountTxCountByCurrentPeriodOffset(
            beamioUserCard,
            account,
            PERIOD_YEAR,
            periodOffset,
            txCategoryFilter,
            accountMode,
            chainIdFilter
        );
    }

    function _copyRoute(LibActionStorage.RouteItem[] storage src)
        internal
        view
        returns (LibActionStorage.RouteItem[] memory dst)
    {
        dst = new LibActionStorage.RouteItem[](src.length);
        for (uint256 i = 0; i < src.length; i++) dst[i] = src[i];
    }

    function _buildFullTransaction(
        LibActionStorage.TransactionRecord storage txr,
        LibActionStorage.RouteItem[] storage routeStore
    ) internal view returns (TransactionFull memory full_) {
        full_.id = txr.id;
        full_.originalPaymentHash = txr.originalPaymentHash;
        full_.chainId = txr.chainId;
        full_.txCategory = txr.txCategory;
        full_.displayJson = txr.displayJson;
        full_.timestamp = txr.timestamp;
        full_.payer = txr.payer;
        full_.payee = txr.payee;
        full_.finalRequestAmountFiat6 = txr.finalRequestAmountFiat6;
        full_.finalRequestAmountUSDC6 = txr.finalRequestAmountUSDC6;
        full_.isAAAccount = txr.isAAAccount;
        full_.topAdmin = txr.topAdmin;
        full_.subordinate = txr.subordinate;
        full_.route = _copyRoute(routeStore);
        full_.fees = txr.fees;
        full_.meta = txr.meta;
    }

    function _getAssetTransactionsByRangePaged(
        address asset,
        address account,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total, LibActionStorage.TransactionRecord[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter) && _matchAccount(txr, account)) total++;
        }
        if (pageOffset >= total || pageLimit == 0) return (total, new LibActionStorage.TransactionRecord[](0));
        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new LibActionStorage.TransactionRecord[](end - pageOffset);
        uint256 seen;
        uint256 outIdx;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 actionId = ids[i];
            LibActionStorage.TransactionRecord storage txr2 = a.txRecordByActionId[actionId];
            if (!_matchByPeriodAndCategory(txr2, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter) || !_matchAccount(txr2, account)) continue;
            if (seen >= pageOffset && seen < end) page[outIdx++] = txr2;
            seen++;
            if (seen >= end) break;
        }
    }

    function _getAssetTransactionsByRangePagedFull(
        address asset,
        address account,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total, TransactionFull[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter) && _matchAccount(txr, account)) total++;
        }
        if (pageOffset >= total || pageLimit == 0) return (total, new TransactionFull[](0));
        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new TransactionFull[](end - pageOffset);
        uint256 seen;
        uint256 outIdx;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 actionId = ids[i];
            LibActionStorage.TransactionRecord storage txr2 = a.txRecordByActionId[actionId];
            if (!_matchByPeriodAndCategory(txr2, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter) || !_matchAccount(txr2, account)) continue;
            if (seen >= pageOffset && seen < end) page[outIdx++] = _buildFullTransaction(txr2, a.routeByActionId[actionId]);
            seen++;
            if (seen >= end) break;
        }
    }

    function _getAssetTransactionsByTopAdminRangePaged(
        address asset,
        address topAdmin,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total, LibActionStorage.TransactionRecord[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (txr.topAdmin != topAdmin) continue;
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) total++;
        }
        if (pageOffset >= total || pageLimit == 0) return (total, new LibActionStorage.TransactionRecord[](0));
        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new LibActionStorage.TransactionRecord[](end - pageOffset);
        uint256 seen;
        uint256 outIdx;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 actionId = ids[i];
            LibActionStorage.TransactionRecord storage txr2 = a.txRecordByActionId[actionId];
            if (txr2.topAdmin != topAdmin) continue;
            if (!_matchByPeriodAndCategory(txr2, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) continue;
            if (seen >= pageOffset && seen < end) page[outIdx++] = txr2;
            seen++;
            if (seen >= end) break;
        }
    }

    function _getAssetTransactionsByTopAdminRangePagedFull(
        address asset,
        address topAdmin,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total, TransactionFull[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (txr.topAdmin != topAdmin) continue;
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) total++;
        }
        if (pageOffset >= total || pageLimit == 0) return (total, new TransactionFull[](0));
        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new TransactionFull[](end - pageOffset);
        uint256 seen;
        uint256 outIdx;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 actionId = ids[i];
            LibActionStorage.TransactionRecord storage txr2 = a.txRecordByActionId[actionId];
            if (txr2.topAdmin != topAdmin) continue;
            if (!_matchByPeriodAndCategory(txr2, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) continue;
            if (seen >= pageOffset && seen < end) page[outIdx++] = _buildFullTransaction(txr2, a.routeByActionId[actionId]);
            seen++;
            if (seen >= end) break;
        }
    }

    function _getAssetTransactionsBySubordinateRangePaged(
        address asset,
        address subordinate,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total, LibActionStorage.TransactionRecord[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (txr.subordinate != subordinate) continue;
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) total++;
        }
        if (pageOffset >= total || pageLimit == 0) return (total, new LibActionStorage.TransactionRecord[](0));
        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new LibActionStorage.TransactionRecord[](end - pageOffset);
        uint256 seen;
        uint256 outIdx;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 actionId = ids[i];
            LibActionStorage.TransactionRecord storage txr2 = a.txRecordByActionId[actionId];
            if (txr2.subordinate != subordinate) continue;
            if (!_matchByPeriodAndCategory(txr2, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) continue;
            if (seen >= pageOffset && seen < end) page[outIdx++] = txr2;
            seen++;
            if (seen >= end) break;
        }
    }

    function _getAssetTransactionsBySubordinateRangePagedFull(
        address asset,
        address subordinate,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total, TransactionFull[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (txr.subordinate != subordinate) continue;
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) total++;
        }
        if (pageOffset >= total || pageLimit == 0) return (total, new TransactionFull[](0));
        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new TransactionFull[](end - pageOffset);
        uint256 seen;
        uint256 outIdx;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 actionId = ids[i];
            LibActionStorage.TransactionRecord storage txr2 = a.txRecordByActionId[actionId];
            if (txr2.subordinate != subordinate) continue;
            if (!_matchByPeriodAndCategory(txr2, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) continue;
            if (seen >= pageOffset && seen < end) page[outIdx++] = _buildFullTransaction(txr2, a.routeByActionId[actionId]);
            seen++;
            if (seen >= end) break;
        }
    }

    function _getAssetTokenTransactionsByRangePaged(
        address asset,
        uint256 tokenId,
        address account,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total, LibActionStorage.TransactionRecord[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetTokenActionIds[asset][tokenId];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter) && _matchAccount(txr, account)) total++;
        }
        if (pageOffset >= total || pageLimit == 0) return (total, new LibActionStorage.TransactionRecord[](0));
        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new LibActionStorage.TransactionRecord[](end - pageOffset);
        uint256 seen;
        uint256 outIdx;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 actionId = ids[i];
            LibActionStorage.TransactionRecord storage txr2 = a.txRecordByActionId[actionId];
            if (!_matchByPeriodAndCategory(txr2, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter) || !_matchAccount(txr2, account)) continue;
            if (seen >= pageOffset && seen < end) page[outIdx++] = txr2;
            seen++;
            if (seen >= end) break;
        }
    }

    function _getAssetTokenTransactionsByRangePagedFull(
        address asset,
        uint256 tokenId,
        address account,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total, TransactionFull[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetTokenActionIds[asset][tokenId];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter) && _matchAccount(txr, account)) total++;
        }
        if (pageOffset >= total || pageLimit == 0) return (total, new TransactionFull[](0));
        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new TransactionFull[](end - pageOffset);
        uint256 seen;
        uint256 outIdx;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 actionId = ids[i];
            LibActionStorage.TransactionRecord storage txr2 = a.txRecordByActionId[actionId];
            if (!_matchByPeriodAndCategory(txr2, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter) || !_matchAccount(txr2, account)) continue;
            if (seen >= pageOffset && seen < end) page[outIdx++] = _buildFullTransaction(txr2, a.routeByActionId[actionId]);
            seen++;
            if (seen >= end) break;
        }
    }

    function _countAssetTransactionsByRange(
        address asset,
        uint256 periodStart,
        uint256 periodEnd,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) total++;
        }
    }

    function _countAssetTransactionsByTopAdminRange(
        address asset,
        address topAdmin,
        uint256 periodStart,
        uint256 periodEnd,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (txr.topAdmin != topAdmin) continue;
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) total++;
        }
    }

    function _countAssetTransactionsBySubordinateRange(
        address asset,
        address subordinate,
        uint256 periodStart,
        uint256 periodEnd,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (txr.subordinate != subordinate) continue;
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter)) total++;
        }
    }

    function _countAssetAccountTransactionsByRange(
        address asset,
        address account,
        uint256 periodStart,
        uint256 periodEnd,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 total) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[asset];
        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (_matchByPeriodAndCategory(txr, periodStart, periodEnd, txCategoryFilter, accountMode, chainIdFilter) && _matchAccount(txr, account)) {
                total++;
            }
        }
    }

    function _countBeamioUserCardMintStatsByRange(
        address beamioUserCard,
        uint256 periodStart,
        uint256 periodEnd,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 mintTxTotal, uint256 mintWalletCount) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetActionIds[beamioUserCard];
        address[] memory wallets = new address[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (!_matchByPeriodAndCategory(txr, periodStart, periodEnd, mintTxCategoryFilter, accountMode, chainIdFilter)) {
                continue;
            }
            mintTxTotal++;

            address wallet = txr.payee;
            bool seen;
            for (uint256 j = 0; j < mintWalletCount; j++) {
                if (wallets[j] == wallet) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                wallets[mintWalletCount] = wallet;
                mintWalletCount++;
            }
        }
    }

    function _countBeamioUserCardTokenMintStatsByRange(
        address beamioUserCard,
        uint256 tokenId,
        uint256 periodStart,
        uint256 periodEnd,
        bytes32 mintTxCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (uint256 mintTxTotal, uint256 mintWalletCount) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.assetTokenActionIds[beamioUserCard][tokenId];
        address[] memory wallets = new address[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[ids[i]];
            if (!_matchByPeriodAndCategory(txr, periodStart, periodEnd, mintTxCategoryFilter, accountMode, chainIdFilter)) {
                continue;
            }
            mintTxTotal++;

            address wallet = txr.payee;
            bool seen;
            for (uint256 j = 0; j < mintWalletCount; j++) {
                if (wallets[j] == wallet) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                wallets[mintWalletCount] = wallet;
                mintWalletCount++;
            }
        }
    }

    function _topHoldersAtHour(
        address asset,
        uint256 tokenId,
        uint64 targetHour,
        uint256 topN
    ) internal view returns (address[] memory holders, uint256[] memory balances) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        address[] storage seen = a.assetTokenSeenAccounts[asset][tokenId];
        if (seen.length == 0) return (new address[](0), new uint256[](0));

        address[] memory tmpHolders = new address[](topN);
        uint256[] memory tmpBalances = new uint256[](topN);
        uint256 count = 0;

        for (uint256 i = 0; i < seen.length; i++) {
            address acct = seen[i];
            uint256 bal = _balanceAtOrBeforeHour(a.assetTokenBalanceCheckpoints[asset][tokenId][acct], targetHour);
            if (bal == 0) continue;

            if (count < topN) {
                tmpHolders[count] = acct;
                tmpBalances[count] = bal;
                _bubbleUpTopEntry(tmpHolders, tmpBalances, count);
                count++;
            } else if (bal > tmpBalances[topN - 1]) {
                tmpHolders[topN - 1] = acct;
                tmpBalances[topN - 1] = bal;
                _bubbleUpTopEntry(tmpHolders, tmpBalances, topN - 1);
            }
        }

        holders = new address[](count);
        balances = new uint256[](count);
        for (uint256 j = 0; j < count; j++) {
            holders[j] = tmpHolders[j];
            balances[j] = tmpBalances[j];
        }
    }

    function _bubbleUpTopEntry(
        address[] memory holders,
        uint256[] memory balances,
        uint256 idx
    ) internal pure {
        while (idx > 0 && balances[idx] > balances[idx - 1]) {
            uint256 b = balances[idx - 1];
            balances[idx - 1] = balances[idx];
            balances[idx] = b;

            address h = holders[idx - 1];
            holders[idx - 1] = holders[idx];
            holders[idx] = h;
            idx--;
        }
    }

    function _balanceAtOrBeforeHour(
        LibActionStorage.BalanceCheckpoint[] storage cps,
        uint64 targetHour
    ) internal view returns (uint256) {
        uint256 len = cps.length;
        if (len == 0) return 0;
        if (cps[0].hourIndex > targetHour) return 0;

        uint256 lo = 0;
        uint256 hi = len;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].hourIndex <= targetHour) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return cps[lo - 1].balanceE6;
    }

    function _matchByPeriodAndCategory(
        LibActionStorage.TransactionRecord storage txr,
        uint256 periodStart,
        uint256 periodEnd,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint256 chainIdFilter
    ) internal view returns (bool) {
        if (!txr.exists) return false;
        if (uint256(txr.timestamp) < periodStart || uint256(txr.timestamp) > periodEnd) return false;
        if (txCategoryFilter != bytes32(0) && txr.txCategory != txCategoryFilter) return false;
        if (accountMode == ACCOUNT_MODE_EOA && txr.isAAAccount) return false;
        if (accountMode == ACCOUNT_MODE_AA && !txr.isAAAccount) return false;
        if (chainIdFilter != CHAIN_ID_FILTER_ALL && txr.chainId != chainIdFilter) return false;
        return true;
    }

    function _matchAccount(LibActionStorage.TransactionRecord storage txr, address account) internal view returns (bool) {
        if (account == address(0)) return true;
        return txr.payer == account || txr.payee == account;
    }

    function _isValidAccountMode(uint8 accountMode) internal pure returns (bool) {
        return accountMode == ACCOUNT_MODE_ALL || accountMode == ACCOUNT_MODE_EOA || accountMode == ACCOUNT_MODE_AA;
    }

    function _isValidChainIdFilter(uint256 chainIdFilter) internal pure returns (bool) {
        return chainIdFilter == CHAIN_ID_FILTER_ALL || chainIdFilter > 0;
    }

    function _isValidActionPeriodType(uint8 periodType) internal pure returns (bool) {
        return
            periodType == PERIOD_HOUR ||
            periodType == PERIOD_DAY ||
            periodType == PERIOD_WEEK ||
            periodType == PERIOD_MONTH ||
            periodType == PERIOD_QUARTER ||
            periodType == PERIOD_YEAR;
    }

    function _shiftPeriodStartBack(uint256 startTs, uint8 periodType, uint256 periodOffset) internal pure returns (uint256) {
        if (periodOffset == 0) return startTs;
        if (periodType == PERIOD_HOUR) return startTs - (periodOffset * 1 hours);
        if (periodType == PERIOD_DAY) return startTs - (periodOffset * 1 days);
        if (periodType == PERIOD_WEEK) return startTs - (periodOffset * 7 days);
        uint256 s = startTs;
        for (uint256 i = 0; i < periodOffset; i++) s = _previousPeriodStart(s, periodType);
        return s;
    }

    function _periodEndFromStart(uint256 startTs, uint8 periodType) internal pure returns (uint256) {
        if (periodType == PERIOD_HOUR) return startTs + 1 hours - 1;
        if (periodType == PERIOD_DAY) return startTs + 1 days - 1;
        if (periodType == PERIOD_WEEK) return startTs + 7 days - 1;
        (uint256 year, uint256 month, ) = _daysToDate(startTs / 1 days);
        uint256 nextStart;
        if (periodType == PERIOD_MONTH) {
            (uint256 y, uint256 m) = _addMonths(year, month, 1);
            nextStart = _timestampFromDate(y, m, 1);
            return nextStart - 1;
        }
        if (periodType == PERIOD_QUARTER) {
            (uint256 y2, uint256 m2) = _addMonths(year, month, 3);
            nextStart = _timestampFromDate(y2, m2, 1);
            return nextStart - 1;
        }
        nextStart = _timestampFromDate(year + 1, 1, 1);
        return nextStart - 1;
    }

    function _previousPeriodStart(uint256 currentStart, uint8 periodType) internal pure returns (uint256) {
        if (periodType == PERIOD_HOUR) return currentStart - 1 hours;
        if (periodType == PERIOD_DAY) return currentStart - 1 days;
        if (periodType == PERIOD_WEEK) return currentStart - 7 days;
        (uint256 year, uint256 month, ) = _daysToDate(currentStart / 1 days);
        if (periodType == PERIOD_MONTH) {
            (uint256 y, uint256 m) = _addMonths(year, month, -1);
            return _timestampFromDate(y, m, 1);
        }
        if (periodType == PERIOD_QUARTER) {
            (uint256 y2, uint256 m2) = _addMonths(year, month, -3);
            return _timestampFromDate(y2, m2, 1);
        }
        return _timestampFromDate(year - 1, 1, 1);
    }

    function _resolveActionPeriodRange(uint256 ts, uint8 periodType) internal pure returns (uint256 startTs, uint256 endTs) {
        if (periodType == PERIOD_HOUR) {
            startTs = (ts / 1 hours) * 1 hours;
            endTs = startTs + 1 hours - 1;
            return (startTs, endTs);
        }
        if (periodType == PERIOD_DAY) {
            startTs = (ts / 1 days) * 1 days;
            endTs = startTs + 1 days - 1;
            return (startTs, endTs);
        }
        uint256 daysSinceEpoch = ts / 1 days;
        if (periodType == PERIOD_WEEK) {
            uint256 mondayIndex = (daysSinceEpoch + 3) % 7;
            startTs = (daysSinceEpoch - mondayIndex) * 1 days;
            endTs = startTs + 7 days - 1;
            return (startTs, endTs);
        }
        (uint256 year, uint256 month, ) = _daysToDate(daysSinceEpoch);
        if (periodType == PERIOD_MONTH) {
            startTs = _timestampFromDate(year, month, 1);
            (uint256 y1, uint256 m1) = _addMonths(year, month, 1);
            endTs = _timestampFromDate(y1, m1, 1) - 1;
            return (startTs, endTs);
        }
        if (periodType == PERIOD_QUARTER) {
            uint256 quarterStartMonth = ((month - 1) / 3) * 3 + 1;
            startTs = _timestampFromDate(year, quarterStartMonth, 1);
            (uint256 y2, uint256 m2) = _addMonths(year, quarterStartMonth, 3);
            endTs = _timestampFromDate(y2, m2, 1) - 1;
            return (startTs, endTs);
        }
        startTs = _timestampFromDate(year, 1, 1);
        endTs = _timestampFromDate(year + 1, 1, 1) - 1;
    }

    function _timestampFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        return _daysFromDate(year, month, day) * 1 days;
    }

    function _addMonths(uint256 year, uint256 month, int256 offset) internal pure returns (uint256 ny, uint256 nm) {
        int256 ym = int256(year) * 12 + int256(month) - 1 + offset;
        require(ym >= 0, "date underflow");
        ny = uint256(ym / 12);
        nm = uint256(ym % 12) + 1;
    }

    function _daysFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256 _days) {
        require(year >= 1970, "year<1970");
        int256 _year = int256(year);
        int256 _month = int256(month);
        int256 _day = int256(day);
        int256 __days = _day
            - 32075
            + (1461 * (_year + 4800 + (_month - 14) / 12)) / 4
            + (367 * (_month - 2 - ((_month - 14) / 12) * 12)) / 12
            - (3 * ((_year + 4900 + (_month - 14) / 12) / 100)) / 4
            - 2440588;
        _days = uint256(__days);
    }

    function _daysToDate(uint256 _days) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 __days = int256(_days);
        int256 L = __days + 68569 + 2440588;
        int256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 _year = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * _year) / 4 + 31;
        int256 _month = (80 * L) / 2447;
        int256 _day = L - (2447 * _month) / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;
        year = uint256(_year);
        month = uint256(_month);
        day = uint256(_day);
    }
}
