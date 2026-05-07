// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibActionStorage} from "../libraries/LibActionStorage.sol";
import {LibStatsStorage} from "../libraries/LibStatsStorage.sol";
import {LibAdminStorage} from "../libraries/LibAdminStorage.sol";

contract ActionFacet {
    uint8 public constant PERIOD_HOUR = 0;
    uint8 public constant PERIOD_DAY = 1;
    uint8 public constant PERIOD_WEEK = 2;
    uint8 public constant PERIOD_MONTH = 3;
    uint8 public constant PERIOD_QUARTER = 4;
    uint8 public constant PERIOD_YEAR = 5;
    uint8 public constant ACCOUNT_MODE_ALL = 0;
    uint8 public constant ACCOUNT_MODE_EOA = 1;
    uint8 public constant ACCOUNT_MODE_AA = 2;
    uint16 public constant GAS_CHAIN_FILTER_ALL = type(uint16).max;
    uint256 public constant CHAIN_ID_FILTER_ALL = type(uint256).max;
    uint256 public constant ATOMIC_BUCKET_SECONDS = 3600;

    event StatsUpdated(uint256 indexed hourIndex, address indexed account);
    event TransactionRecordSynced(
        uint256 indexed actionId,
        bytes32 indexed txId,
        bytes32 indexed txCategory,
        address payer,
        address payee
    );
    event AfterNotesUpdated(uint256 indexed actionId);
    /// @dev 一次性 backfill：把范围 [fromActionId, toActionId) 的 subordinate 并入 accountActionIds
    event SubordinateAccountIndexBackfilled(uint256 fromActionId, uint256 toActionId, uint256 pushed);

    /// @dev ActionFacet 私有 diamond storage slot（不污染 LibActionStorage.Layout，便于未来追加字段）
    bytes32 internal constant _ACTION_FACET_SUBORDINATE_BACKFILL_SLOT =
        keccak256("beamio.indexer.actionfacet.subordinatebackfill.v1");

    struct SubordinateBackfillStorage {
        mapping(uint256 => bool) done;
    }

    function _subordinateBackfillStorage() internal pure returns (SubordinateBackfillStorage storage s) {
        bytes32 slot = _ACTION_FACET_SUBORDINATE_BACKFILL_SLOT;
        assembly { s.slot := slot }
    }

    struct RouteItemInput {
        address asset;
        uint256 amountE6;
        uint8 assetType;
        uint8 source;
        uint256 tokenId;
        uint8 itemCurrencyType;
        uint256 offsetInRequestCurrencyE6;
    }

    struct FeeInfoInput {
        uint16 gasChainType;
        uint256 gasWei;
        uint256 gasUSDC6;
        uint256 serviceUSDC6;
        uint256 bServiceUSDC6;
        uint256 bServiceUnits6;
        address feePayer;
    }

    struct TransactionMetaInput {
        uint256 requestAmountFiat6;
        uint256 requestAmountUSDC6;
        uint8 currencyFiat;
        uint256 discountAmountFiat6;
        uint16 discountRateBps;
        uint256 taxAmountFiat6;
        uint16 taxRateBps;
        string afterNotePayer;
        string afterNotePayee;
    }

    struct TransactionInput {
        bytes32 txId;
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
        RouteItemInput[] route;
        FeeInfoInput fees;
        TransactionMetaInput meta;
        /// @dev 当为 admin 操作（如 mintPointsByAdmin）时传入 admin 地址，用于 token #0 按 admin 维度统计 mint/burn
        address operator;
        /// @dev operator 的 parent 链（从直接 parent 到根），B 的 mint/burn 也累积到链上各 admin 的统计
        address[] operatorParentChain;
        /// @dev top-level admin (owner or direct admin) for reporting
        address topAdmin;
        /// @dev terminal/subordinate that processed this tx for reporting
        address subordinate;
    }

    // 完整返回模型：与 readme Transaction 结构对齐（含 route）
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

    function _enforceIsOwnerOrAdmin() internal view {
        if (msg.sender == LibDiamond.contractOwner()) return;
        require(LibAdminStorage.layout().isAdmin[msg.sender], "not admin");
    }

    function syncTokenAction(TransactionInput calldata in_) external returns (uint256 actionId) {
        _enforceIsOwnerOrAdmin();

        require(in_.txId != bytes32(0), "txId=0");
        require(in_.chainId > 0, "chainId=0");
        require(in_.payer != address(0), "payer=0");
        require(in_.payee != address(0), "payee=0");
        if (in_.isAAAccount) require(in_.route.length > 0, "route required");
        require(
            in_.fees.gasChainType <= uint16(LibActionStorage.GasChainType.SOLANA),
            "bad gasChainType"
        );

        LibActionStorage.Layout storage a = LibActionStorage.layout();
        require(a.actionIdPlusOneByTxId[in_.txId] == 0, "tx exists");

        actionId = a.txCount;
        a.txCount = actionId + 1;

        uint256 useTs = in_.timestamp == 0 ? block.timestamp : uint256(in_.timestamp);
        LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[actionId];

        txr.id = in_.txId;
        txr.originalPaymentHash = in_.originalPaymentHash;
        txr.chainId = in_.chainId;
        txr.txCategory = in_.txCategory;
        txr.displayJson = in_.displayJson;
        txr.timestamp = uint64(useTs);
        txr.payer = in_.payer;
        txr.payee = in_.payee;
        txr.finalRequestAmountFiat6 = in_.finalRequestAmountFiat6;
        txr.finalRequestAmountUSDC6 = in_.finalRequestAmountUSDC6;
        txr.isAAAccount = in_.isAAAccount;
        txr.topAdmin = in_.topAdmin;
        txr.subordinate = in_.subordinate;
        txr.exists = true;

        txr.fees = LibActionStorage.FeeInfo({
            gasChainType: in_.fees.gasChainType,
            gasWei: in_.fees.gasWei,
            gasUSDC6: in_.fees.gasUSDC6,
            serviceUSDC6: in_.fees.serviceUSDC6,
            bServiceUSDC6: in_.fees.bServiceUSDC6,
            bServiceUnits6: in_.fees.bServiceUnits6,
            feePayer: in_.fees.feePayer
        });

        txr.meta = LibActionStorage.TransactionMeta({
            requestAmountFiat6: in_.meta.requestAmountFiat6,
            requestAmountUSDC6: in_.meta.requestAmountUSDC6,
            currencyFiat: in_.meta.currencyFiat,
            discountAmountFiat6: in_.meta.discountAmountFiat6,
            discountRateBps: in_.meta.discountRateBps,
            taxAmountFiat6: in_.meta.taxAmountFiat6,
            taxRateBps: in_.meta.taxRateBps,
            afterNotePayer: in_.meta.afterNotePayer,
            afterNotePayee: in_.meta.afterNotePayee
        });

        LibActionStorage.RouteItem[] storage routeStore = a.routeByActionId[actionId];
        for (uint256 i = 0; i < in_.route.length; i++) {
            RouteItemInput calldata r = in_.route[i];
            require(r.asset != address(0), "route.asset=0");
            require(r.amountE6 > 0, "route.amount=0");
            require(r.assetType <= uint8(LibActionStorage.AssetType.ERC1155), "bad assetType");
            require(r.source <= uint8(LibActionStorage.RouteSource.TipAppend), "bad route source");

            routeStore.push(
                LibActionStorage.RouteItem({
                    asset: r.asset,
                    amountE6: r.amountE6,
                    assetType: LibActionStorage.AssetType(r.assetType),
                    source: LibActionStorage.RouteSource(r.source),
                    tokenId: r.tokenId,
                    itemCurrencyType: r.itemCurrencyType,
                    offsetInRequestCurrencyE6: r.offsetInRequestCurrencyE6
                })
            );

            _indexAssetAction(a, r.asset, actionId);
            _indexAssetTokenAction(a, r.asset, r.tokenId, actionId);
            _applyAssetTokenTransfer(a, r.asset, r.tokenId, in_.payer, in_.payee, r.amountE6, uint64(useTs / 3600));
        }

        a.actionIdPlusOneByTxId[in_.txId] = actionId + 1;
        a.accountActionIds[in_.payer].push(actionId);
        if (in_.payee != in_.payer) a.accountActionIds[in_.payee].push(actionId);
        // POS subordinate (terminal/经手人) 也并入按账户分页索引，便于
        // `getAccountTransactionsPaged(POS_EOA)` 直接返回 POS 经手记录。
        // 与 payer/payee 去重以避免同一 actionId 在数组中重复。
        if (
            in_.subordinate != address(0) &&
            in_.subordinate != in_.payer &&
            in_.subordinate != in_.payee
        ) {
            a.accountActionIds[in_.subordinate].push(actionId);
        }
        if (in_.fees.feePayer != address(0)) {
            a.feePayerActionIds[in_.fees.feePayer].push(actionId);
            if (in_.fees.bServiceUnits6 > 0 && !a.bServiceSeenAccountIndexed[in_.fees.feePayer]) {
                a.bServiceSeenAccountIndexed[in_.fees.feePayer] = true;
                a.bServiceSeenAccounts.push(in_.fees.feePayer);
            }
        }
        if (in_.topAdmin != address(0)) a.topAdminActionIds[in_.topAdmin].push(actionId);
        if (in_.subordinate != address(0)) a.subordinateActionIds[in_.subordinate].push(actionId);

        _recordTxStats(useTs, in_.payer, in_.payee);

        if (in_.operator != address(0)) {
            uint256 token0Mint = 0;
            uint256 token0Burn = 0;
            address cardAddr = address(0);
            for (uint256 i = 0; i < in_.route.length; i++) {
                RouteItemInput calldata r = in_.route[i];
                if (r.source == uint8(LibActionStorage.RouteSource.UserCardPoint)) {
                    token0Mint += r.amountE6;
                    if (cardAddr == address(0) && r.asset != address(0)) cardAddr = r.asset;
                }
            }
            if (token0Mint > 0 || token0Burn > 0) {
                _recordAdminToken0Stats(useTs, in_.operator, token0Mint, token0Burn);
                for (uint256 j = 0; j < in_.operatorParentChain.length; j++) {
                    if (in_.operatorParentChain[j] != address(0)) {
                        _recordAdminToken0Stats(useTs, in_.operatorParentChain[j], token0Mint, token0Burn);
                    }
                }
                if (cardAddr != address(0)) {
                    _addAdminMintCounterByCard(cardAddr, in_.operator, token0Mint);
                    for (uint256 j = 0; j < in_.operatorParentChain.length; j++) {
                        if (in_.operatorParentChain[j] != address(0)) {
                            _addAdminMintCounterByCard(cardAddr, in_.operatorParentChain[j], token0Mint);
                        }
                    }
                }
            }
        }

        emit TransactionRecordSynced(actionId, in_.txId, in_.txCategory, in_.payer, in_.payee);
    }

    function _indexAssetAction(
        LibActionStorage.Layout storage a,
        address asset,
        uint256 actionId
    ) internal {
        if (!a.assetActionIndexed[asset][actionId]) {
            a.assetActionIndexed[asset][actionId] = true;
            a.assetActionIds[asset].push(actionId);
        }
    }

    function _indexAssetTokenAction(
        LibActionStorage.Layout storage a,
        address asset,
        uint256 tokenId,
        uint256 actionId
    ) internal {
        if (!a.assetTokenActionIndexed[asset][tokenId][actionId]) {
            a.assetTokenActionIndexed[asset][tokenId][actionId] = true;
            a.assetTokenActionIds[asset][tokenId].push(actionId);
        }
    }

    function _applyAssetTokenTransfer(
        LibActionStorage.Layout storage a,
        address asset,
        uint256 tokenId,
        address from,
        address to,
        uint256 amountE6,
        uint64 hourIndex
    ) internal {
        if (amountE6 == 0 || from == to) return;

        uint256 fromBal = a.indexedBalanceByAssetTokenAccount[asset][tokenId][from];
        uint256 debit = amountE6 > fromBal ? fromBal : amountE6;
        if (debit == 0) return;
        uint256 newFromBal = fromBal - debit;
        a.indexedBalanceByAssetTokenAccount[asset][tokenId][from] = newFromBal;
        if (fromBal > 0 && newFromBal == 0) {
            a.indexedHolderCountByAssetToken[asset][tokenId] -= 1;
        }
        _recordBalanceCheckpoint(a, asset, tokenId, from, newFromBal, hourIndex);

        uint256 toBal = a.indexedBalanceByAssetTokenAccount[asset][tokenId][to];
        if (toBal == 0) {
            a.indexedHolderCountByAssetToken[asset][tokenId] += 1;
        }
        // indexer 口径：若历史不完整导致 from 余额不足，按可扣减部分 debit 处理
        uint256 newToBal = toBal + debit;
        a.indexedBalanceByAssetTokenAccount[asset][tokenId][to] = newToBal;
        _recordBalanceCheckpoint(a, asset, tokenId, to, newToBal, hourIndex);
    }

    function _recordBalanceCheckpoint(
        LibActionStorage.Layout storage a,
        address asset,
        uint256 tokenId,
        address account,
        uint256 balanceE6,
        uint64 hourIndex
    ) internal {
        if (!a.assetTokenSeenAccountIndexed[asset][tokenId][account]) {
            a.assetTokenSeenAccountIndexed[asset][tokenId][account] = true;
            a.assetTokenSeenAccounts[asset][tokenId].push(account);
        }

        LibActionStorage.BalanceCheckpoint[] storage cps = a.assetTokenBalanceCheckpoints[asset][tokenId][account];
        uint256 len = cps.length;
        if (len > 0 && cps[len - 1].hourIndex == hourIndex) {
            cps[len - 1].balanceE6 = balanceE6;
            return;
        }
        cps.push(LibActionStorage.BalanceCheckpoint({hourIndex: hourIndex, balanceE6: balanceE6}));
    }

    function _recordTxStats(uint256 ts, address payer, address payee) internal {
        LibStatsStorage.Layout storage s = LibStatsStorage.layout();
        uint256 hourIndex = ts / 3600;
        _upd(s.hourlyData[hourIndex], 0, 0, 0, 1);
        _upd(s.userHourlyData[payer][hourIndex], 0, 0, 0, 1);
        emit StatsUpdated(hourIndex, payer);

        if (payee != payer) {
            _upd(s.userHourlyData[payee][hourIndex], 0, 0, 0, 1);
            emit StatsUpdated(hourIndex, payee);
        }
    }

    function _recordAdminToken0Stats(uint256 ts, address admin, uint256 mintAmount, uint256 burnAmount) internal {
        LibStatsStorage.Layout storage s = LibStatsStorage.layout();
        uint256 hourIndex = ts / 3600;
        _upd(s.adminHourlyData[admin][hourIndex], 0, mintAmount, burnAmount, 0);
    }

    function _addAdminMintCounterByCard(address card, address admin, uint256 mintAmount) internal {
        if (card == address(0) || admin == address(0) || mintAmount == 0) return;
        LibStatsStorage.layout().adminMintCounterByCard[card][admin] += mintAmount;
    }

    function _upd(
        LibStatsStorage.HourlyStats storage st,
        uint256 nft,
        uint256 mint,
        uint256 burn,
        uint256 trans
    ) internal {
        if (!st.hasData) st.hasData = true;
        st.nftMinted += nft;
        st.tokenMinted += mint;
        st.tokenBurned += burn;
        st.transferCount += trans;
    }

    function setAfterNotes(
        uint256 actionId,
        string calldata afterNotePayer,
        string calldata afterNotePayee
    ) external {
        _enforceIsOwnerOrAdmin();
        _requireActionExists(actionId);
        LibActionStorage.TransactionMeta storage m = LibActionStorage.layout().txRecordByActionId[actionId].meta;
        m.afterNotePayer = afterNotePayer;
        m.afterNotePayee = afterNotePayee;
        emit AfterNotesUpdated(actionId);
    }

    function getTransactionCount() external view returns (uint256) {
        return LibActionStorage.layout().txCount;
    }

    function getTransactionRecord(uint256 actionId)
        external
        view
        returns (LibActionStorage.TransactionRecord memory tx_, LibActionStorage.RouteItem[] memory route_)
    {
        _requireActionExists(actionId);
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        tx_ = a.txRecordByActionId[actionId];
        route_ = _copyRoute(a.routeByActionId[actionId]);
    }

    function getTransactionFull(uint256 actionId) external view returns (TransactionFull memory full_) {
        _requireActionExists(actionId);
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        full_ = _buildFullTransaction(a.txRecordByActionId[actionId], a.routeByActionId[actionId]);
    }

    function getTransactionRecordByTxId(bytes32 txId)
        external
        view
        returns (LibActionStorage.TransactionRecord memory tx_, LibActionStorage.RouteItem[] memory route_)
    {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256 actionIdPlusOne = a.actionIdPlusOneByTxId[txId];
        require(actionIdPlusOne != 0, "tx not found");
        uint256 actionId = actionIdPlusOne - 1;
        tx_ = a.txRecordByActionId[actionId];
        route_ = _copyRoute(a.routeByActionId[actionId]);
    }

    function getTransactionFullByTxId(bytes32 txId) external view returns (TransactionFull memory full_) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256 actionIdPlusOne = a.actionIdPlusOneByTxId[txId];
        require(actionIdPlusOne != 0, "tx not found");
        uint256 actionId = actionIdPlusOne - 1;
        full_ = _buildFullTransaction(a.txRecordByActionId[actionId], a.routeByActionId[actionId]);
    }

    function getTransactionActionId(bytes32 txId) external view returns (uint256 actionId, bool exists) {
        uint256 actionIdPlusOne = LibActionStorage.layout().actionIdPlusOneByTxId[txId];
        if (actionIdPlusOne == 0) return (0, false);
        return (actionIdPlusOne - 1, true);
    }

    /**
     * @notice 全局最新交易分页（按 actionId 倒序：最新在前）
     * @dev offset=0 即最新第一页；limit=20 可直接取“全局最新20条”
     */
    function getLatestTransactionsPaged(uint256 offset, uint256 limit)
        external
        view
        returns (uint256 total, LibActionStorage.TransactionRecord[] memory page)
    {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        total = a.txCount;
        if (offset >= total || limit == 0) {
            return (total, new LibActionStorage.TransactionRecord[](0));
        }

        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new LibActionStorage.TransactionRecord[](end - offset);

        for (uint256 i = 0; i < page.length; i++) {
            uint256 actionId = total - 1 - (offset + i);
            page[i] = a.txRecordByActionId[actionId];
        }
    }

    /**
     * @notice 全局最新交易分页（完整结构，含 route）
     * @dev offset=0 即最新第一页；limit=20 可直接取“全局最新20条”
     */
    function getLatestTransactionsPagedFull(uint256 offset, uint256 limit)
        external
        view
        returns (uint256 total, TransactionFull[] memory page)
    {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        total = a.txCount;
        if (offset >= total || limit == 0) {
            return (total, new TransactionFull[](0));
        }

        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new TransactionFull[](end - offset);

        for (uint256 i = 0; i < page.length; i++) {
            uint256 actionId = total - 1 - (offset + i);
            page[i] = _buildFullTransaction(a.txRecordByActionId[actionId], a.routeByActionId[actionId]);
        }
    }

    /**
     * @notice 按 txCategory 的全局最新交易分页（按 actionId 倒序：最新在前）
     * @dev txCategoryFilter=bytes32(0) 表示不过滤分类
     */
    function getLatestTransactionsByCategoryPaged(
        bytes32 txCategoryFilter,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256 total, LibActionStorage.TransactionRecord[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256 txCount = a.txCount;

        for (uint256 i = txCount; i > 0; i--) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[i - 1];
            if (!txr.exists) continue;
            if (txCategoryFilter != bytes32(0) && txr.txCategory != txCategoryFilter) continue;
            total++;
        }

        if (offset >= total || limit == 0) {
            return (total, new LibActionStorage.TransactionRecord[](0));
        }

        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new LibActionStorage.TransactionRecord[](end - offset);

        uint256 seen;
        uint256 outIdx;
        for (uint256 i = txCount; i > 0; i--) {
            uint256 actionId = i - 1;
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[actionId];
            if (!txr.exists) continue;
            if (txCategoryFilter != bytes32(0) && txr.txCategory != txCategoryFilter) continue;

            if (seen >= offset && seen < end) {
                page[outIdx] = txr;
                outIdx++;
            }
            seen++;
            if (seen >= end) break;
        }
    }

    /**
     * @notice 按 txCategory 的全局最新交易分页（完整结构，含 route）
     * @dev txCategoryFilter=bytes32(0) 表示不过滤分类
     */
    function getLatestTransactionsByCategoryPagedFull(
        bytes32 txCategoryFilter,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256 total, TransactionFull[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256 txCount = a.txCount;

        for (uint256 i = txCount; i > 0; i--) {
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[i - 1];
            if (!txr.exists) continue;
            if (txCategoryFilter != bytes32(0) && txr.txCategory != txCategoryFilter) continue;
            total++;
        }

        if (offset >= total || limit == 0) {
            return (total, new TransactionFull[](0));
        }

        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new TransactionFull[](end - offset);

        uint256 seen;
        uint256 outIdx;
        for (uint256 i = txCount; i > 0; i--) {
            uint256 actionId = i - 1;
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[actionId];
            if (!txr.exists) continue;
            if (txCategoryFilter != bytes32(0) && txr.txCategory != txCategoryFilter) continue;

            if (seen >= offset && seen < end) {
                page[outIdx] = _buildFullTransaction(txr, a.routeByActionId[actionId]);
                outIdx++;
            }
            seen++;
            if (seen >= end) break;
        }
    }

    function getAccountActionCount(address account) external view returns (uint256) {
        return LibActionStorage.layout().accountActionIds[account].length;
    }

    function getAccountActionIdsPaged(address account, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page)
    {
        uint256[] storage ids = LibActionStorage.layout().accountActionIds[account];
        uint256 total = ids.length;
        if (offset >= total || limit == 0) return new uint256[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new uint256[](end - offset);
        for (uint256 i = 0; i < page.length; i++) {
            uint256 revIndex = total - 1 - (offset + i);
            page[i] = ids[revIndex];
        }
    }

    function getAccountTransactionsPaged(address account, uint256 offset, uint256 limit)
        external
        view
        returns (LibActionStorage.TransactionRecord[] memory page)
    {
        uint256[] storage ids = LibActionStorage.layout().accountActionIds[account];
        uint256 total = ids.length;
        if (offset >= total || limit == 0) return new LibActionStorage.TransactionRecord[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        page = new LibActionStorage.TransactionRecord[](end - offset);
        for (uint256 i = 0; i < page.length; i++) {
            uint256 revIndex = total - 1 - (offset + i);
            page[i] = a.txRecordByActionId[ids[revIndex]];
        }
    }

    function getAccountActionIdsByPeriodPaged(
        address account,
        uint8 periodType,
        uint256 anchorTs,
        uint256 offset,
        uint256 limit,
        bytes32 txCategoryFilter,
        uint16 gasChainTypeFilter,
        uint256 chainIdFilter
    ) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd, uint256[] memory page) {
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidGasChainTypeFilter(gasChainTypeFilter), "bad gasChainType");
        require(_isValidChainIdFilter(chainIdFilter), "bad chainId");
        // 最小原子粒度为小时，不提供秒级查询
        require(anchorTs == 0 || anchorTs % ATOMIC_BUCKET_SECONDS == 0, "anchor not hour-aligned");
        uint256 useAnchor = anchorTs == 0 ? block.timestamp : anchorTs;
        (periodStart, periodEnd) = _resolveActionPeriodRange(useAnchor, periodType);

        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.accountActionIds[account];

        for (uint256 i = 0; i < ids.length; i++) {
            if (
                _matchByPeriodAndCategory(
                    a.txRecordByActionId[ids[i]],
                    periodStart,
                    periodEnd,
                    txCategoryFilter,
                    ACCOUNT_MODE_ALL,
                    gasChainTypeFilter,
                    chainIdFilter
                )
            ) {
                total++;
            }
        }

        if (offset >= total || limit == 0) {
            return (total, periodStart, periodEnd, new uint256[](0));
        }

        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new uint256[](end - offset);

        uint256 seen;
        uint256 outIdx;
        for (uint256 i = ids.length; i > 0; i--) {
            uint256 actionId = ids[i - 1];
            if (
                !_matchByPeriodAndCategory(
                    a.txRecordByActionId[actionId],
                    periodStart,
                    periodEnd,
                    txCategoryFilter,
                    ACCOUNT_MODE_ALL,
                    gasChainTypeFilter,
                    chainIdFilter
                )
            ) {
                continue;
            }
            if (seen >= offset && seen < end) {
                page[outIdx] = actionId;
                outIdx++;
            }
            seen++;
            if (seen >= end) break;
        }
    }

    function getAccountTransactionsByPeriodPaged(
        address account,
        uint8 periodType,
        uint256 anchorTs,
        uint256 offset,
        uint256 limit,
        bytes32 txCategoryFilter,
        uint16 gasChainTypeFilter,
        uint256 chainIdFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        // 最小原子粒度为小时，不提供秒级查询
        require(anchorTs == 0 || anchorTs % ATOMIC_BUCKET_SECONDS == 0, "anchor not hour-aligned");
        uint256[] memory idsPage;
        (total, periodStart, periodEnd, idsPage) = this.getAccountActionIdsByPeriodPaged(
            account,
            periodType,
            anchorTs,
            offset,
            limit,
            txCategoryFilter,
            gasChainTypeFilter,
            chainIdFilter
        );

        LibActionStorage.Layout storage a = LibActionStorage.layout();
        page = new LibActionStorage.TransactionRecord[](idsPage.length);
        for (uint256 i = 0; i < idsPage.length; i++) {
            page[i] = a.txRecordByActionId[idsPage[i]];
        }
    }

    /**
     * @notice 基于“当前周期”并按 periodOffset 回溯查询
     * @dev periodOffset=0 当前周期；1 上一周期；2 上两周期...
     */
    function getAccountTransactionsByCurrentPeriodOffsetPaged(
        address account,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        require(_isValidActionPeriodType(periodType), "bad periodType");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);

        (total, page) = _getAccountTransactionsByRangePaged(
            account,
            periodStart,
            periodEnd,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            ACCOUNT_MODE_ALL
        );
    }

    /**
     * @notice 同 getAccountTransactionsByCurrentPeriodOffsetPaged，但增加 EOA/AA 过滤
     * @param accountMode 0=全部,1=EOA(isAAAccount=false),2=AA(isAAAccount=true)
     */
    function getAccountTransactionsByCurrentPeriodOffsetAndAccountModePaged(
        address account,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);

        (total, page) = _getAccountTransactionsByRangePaged(
            account,
            periodStart,
            periodEnd,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode
        );
    }

    function getAccountTransactionsByCurrentPeriodOffsetAndAccountModePagedFull(
        address account,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, TransactionFull[] memory page)
    {
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);

        (total, page) = _getAccountTransactionsByRangePagedFull(
            account,
            periodStart,
            periodEnd,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode
        );
    }

    /**
     * @notice 按 topAdmin 查询交易（周期分页 + EOA/AA 过滤）
     */
    function getTopAdminTransactionsByCurrentPeriodOffsetAndAccountModePaged(
        address topAdmin,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        require(topAdmin != address(0), "topAdmin=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);

        (total, page) = _getTopAdminTransactionsByRangePaged(
            topAdmin,
            periodStart,
            periodEnd,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode
        );
    }

    function getTopAdminTransactionsByCurrentPeriodOffsetAndAccountModePagedFull(
        address topAdmin,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, TransactionFull[] memory page)
    {
        require(topAdmin != address(0), "topAdmin=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);

        (total, page) = _getTopAdminTransactionsByRangePagedFull(
            topAdmin,
            periodStart,
            periodEnd,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode
        );
    }

    /**
     * @notice 按 subordinate 查询交易（周期分页 + EOA/AA 过滤）
     */
    function getSubordinateTransactionsByCurrentPeriodOffsetAndAccountModePaged(
        address subordinate,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        require(subordinate != address(0), "subordinate=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);

        (total, page) = _getSubordinateTransactionsByRangePaged(
            subordinate,
            periodStart,
            periodEnd,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode
        );
    }

    function getSubordinateTransactionsByCurrentPeriodOffsetAndAccountModePagedFull(
        address subordinate,
        uint8 periodType,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, TransactionFull[] memory page)
    {
        require(subordinate != address(0), "subordinate=0");
        require(_isValidActionPeriodType(periodType), "bad periodType");
        require(_isValidAccountMode(accountMode), "bad accountMode");
        uint256 currentStart;
        (currentStart, ) = _resolveActionPeriodRange(block.timestamp, periodType);
        periodStart = _shiftPeriodStartBack(currentStart, periodType, periodOffset);
        periodEnd = _periodEndFromStart(periodStart, periodType);

        (total, page) = _getSubordinateTransactionsByRangePagedFull(
            subordinate,
            periodStart,
            periodEnd,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode
        );
    }

    // ---- Convenience wrappers: 本/上 hour/day/week/month/quarter/year ----
    function getAccountTransactionsByHourOffsetPaged(
        address account,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAccountTransactionsByCurrentPeriodOffsetPaged(
            account,
            PERIOD_HOUR,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter
        );
    }

    function getAccountTransactionsByDayOffsetPaged(
        address account,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAccountTransactionsByCurrentPeriodOffsetPaged(
            account,
            PERIOD_DAY,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter
        );
    }

    function getAccountTransactionsByWeekOffsetPaged(
        address account,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAccountTransactionsByCurrentPeriodOffsetPaged(
            account,
            PERIOD_WEEK,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter
        );
    }

    /**
     * @notice 周期=周，并支持 EOA/AA 过滤
     * @param accountMode 0=全部,1=EOA,2=AA
     */
    function getAccountTransactionsByWeekOffsetAndAccountModePaged(
        address account,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAccountTransactionsByCurrentPeriodOffsetAndAccountModePaged(
            account,
            PERIOD_WEEK,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode
        );
    }

    function getTopAdminTransactionsByWeekOffsetAndAccountModePaged(
        address topAdmin,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getTopAdminTransactionsByCurrentPeriodOffsetAndAccountModePaged(
            topAdmin,
            PERIOD_WEEK,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode
        );
    }

    function getSubordinateTransactionsByWeekOffsetAndAccountModePaged(
        address subordinate,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getSubordinateTransactionsByCurrentPeriodOffsetAndAccountModePaged(
            subordinate,
            PERIOD_WEEK,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter,
            accountMode
        );
    }

    function getAccountTransactionsByMonthOffsetPaged(
        address account,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAccountTransactionsByCurrentPeriodOffsetPaged(
            account,
            PERIOD_MONTH,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter
        );
    }

    function getAccountTransactionsByQuarterOffsetPaged(
        address account,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAccountTransactionsByCurrentPeriodOffsetPaged(
            account,
            PERIOD_QUARTER,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter
        );
    }

    function getAccountTransactionsByYearOffsetPaged(
        address account,
        uint256 periodOffset,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter
    )
        external
        view
        returns (uint256 total, uint256 periodStart, uint256 periodEnd, LibActionStorage.TransactionRecord[] memory page)
    {
        return this.getAccountTransactionsByCurrentPeriodOffsetPaged(
            account,
            PERIOD_YEAR,
            periodOffset,
            pageOffset,
            pageLimit,
            txCategoryFilter
        );
    }

    function _copyRoute(LibActionStorage.RouteItem[] storage src)
        internal
        view
        returns (LibActionStorage.RouteItem[] memory dst)
    {
        dst = new LibActionStorage.RouteItem[](src.length);
        for (uint256 i = 0; i < src.length; i++) {
            dst[i] = src[i];
        }
    }

    function _matchByPeriodAndCategory(
        LibActionStorage.TransactionRecord storage txr,
        uint256 periodStart,
        uint256 periodEnd,
        bytes32 txCategoryFilter,
        uint8 accountMode
    ) internal view returns (bool) {
        return
            _matchByPeriodAndCategory(
                txr,
                periodStart,
                periodEnd,
                txCategoryFilter,
                accountMode,
                GAS_CHAIN_FILTER_ALL,
                CHAIN_ID_FILTER_ALL
            );
    }

    function _matchByPeriodAndCategory(
        LibActionStorage.TransactionRecord storage txr,
        uint256 periodStart,
        uint256 periodEnd,
        bytes32 txCategoryFilter,
        uint8 accountMode,
        uint16 gasChainTypeFilter,
        uint256 chainIdFilter
    ) internal view returns (bool) {
        if (!txr.exists) return false;
        if (uint256(txr.timestamp) < periodStart || uint256(txr.timestamp) > periodEnd) return false;
        if (txCategoryFilter != bytes32(0) && txr.txCategory != txCategoryFilter) return false;
        if (accountMode == ACCOUNT_MODE_EOA && txr.isAAAccount) return false;
        if (accountMode == ACCOUNT_MODE_AA && !txr.isAAAccount) return false;
        if (gasChainTypeFilter != GAS_CHAIN_FILTER_ALL && txr.fees.gasChainType != gasChainTypeFilter) return false;
        if (chainIdFilter != CHAIN_ID_FILTER_ALL && txr.chainId != chainIdFilter) return false;
        return true;
    }

    function _getAccountTransactionsByRangePaged(
        address account,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    ) internal view returns (uint256 total, LibActionStorage.TransactionRecord[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.accountActionIds[account];

        for (uint256 i = 0; i < ids.length; i++) {
            if (_matchByPeriodAndCategory(a.txRecordByActionId[ids[i]], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                total++;
            }
        }

        if (pageOffset >= total || pageLimit == 0) {
            return (total, new LibActionStorage.TransactionRecord[](0));
        }

        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new LibActionStorage.TransactionRecord[](end - pageOffset);

        uint256 seen;
        uint256 outIdx;
        for (uint256 i = ids.length; i > 0; i--) {
            uint256 actionId = ids[i - 1];
            if (!_matchByPeriodAndCategory(a.txRecordByActionId[actionId], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                continue;
            }
            if (seen >= pageOffset && seen < end) {
                page[outIdx] = a.txRecordByActionId[actionId];
                outIdx++;
            }
            seen++;
            if (seen >= end) break;
        }
    }

    function _getAccountTransactionsByRangePagedFull(
        address account,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    ) internal view returns (uint256 total, TransactionFull[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.accountActionIds[account];

        for (uint256 i = 0; i < ids.length; i++) {
            if (_matchByPeriodAndCategory(a.txRecordByActionId[ids[i]], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                total++;
            }
        }

        if (pageOffset >= total || pageLimit == 0) {
            return (total, new TransactionFull[](0));
        }

        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new TransactionFull[](end - pageOffset);

        uint256 seen;
        uint256 outIdx;
        for (uint256 i = ids.length; i > 0; i--) {
            uint256 actionId = ids[i - 1];
            if (!_matchByPeriodAndCategory(a.txRecordByActionId[actionId], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                continue;
            }
            if (seen >= pageOffset && seen < end) {
                page[outIdx] = _buildFullTransaction(a.txRecordByActionId[actionId], a.routeByActionId[actionId]);
                outIdx++;
            }
            seen++;
            if (seen >= end) break;
        }
    }

    function _getTopAdminTransactionsByRangePaged(
        address topAdmin,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    ) internal view returns (uint256 total, LibActionStorage.TransactionRecord[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.topAdminActionIds[topAdmin];

        for (uint256 i = 0; i < ids.length; i++) {
            if (_matchByPeriodAndCategory(a.txRecordByActionId[ids[i]], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                total++;
            }
        }

        if (pageOffset >= total || pageLimit == 0) {
            return (total, new LibActionStorage.TransactionRecord[](0));
        }

        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new LibActionStorage.TransactionRecord[](end - pageOffset);

        uint256 seen;
        uint256 outIdx;
        for (uint256 i = ids.length; i > 0; i--) {
            uint256 actionId = ids[i - 1];
            if (!_matchByPeriodAndCategory(a.txRecordByActionId[actionId], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                continue;
            }
            if (seen >= pageOffset && seen < end) {
                page[outIdx] = a.txRecordByActionId[actionId];
                outIdx++;
            }
            seen++;
            if (seen >= end) break;
        }
    }

    function _getTopAdminTransactionsByRangePagedFull(
        address topAdmin,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    ) internal view returns (uint256 total, TransactionFull[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.topAdminActionIds[topAdmin];

        for (uint256 i = 0; i < ids.length; i++) {
            if (_matchByPeriodAndCategory(a.txRecordByActionId[ids[i]], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                total++;
            }
        }

        if (pageOffset >= total || pageLimit == 0) {
            return (total, new TransactionFull[](0));
        }

        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new TransactionFull[](end - pageOffset);

        uint256 seen;
        uint256 outIdx;
        for (uint256 i = ids.length; i > 0; i--) {
            uint256 actionId = ids[i - 1];
            if (!_matchByPeriodAndCategory(a.txRecordByActionId[actionId], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                continue;
            }
            if (seen >= pageOffset && seen < end) {
                page[outIdx] = _buildFullTransaction(a.txRecordByActionId[actionId], a.routeByActionId[actionId]);
                outIdx++;
            }
            seen++;
            if (seen >= end) break;
        }
    }

    function _getSubordinateTransactionsByRangePaged(
        address subordinate,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    ) internal view returns (uint256 total, LibActionStorage.TransactionRecord[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.subordinateActionIds[subordinate];

        for (uint256 i = 0; i < ids.length; i++) {
            if (_matchByPeriodAndCategory(a.txRecordByActionId[ids[i]], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                total++;
            }
        }

        if (pageOffset >= total || pageLimit == 0) {
            return (total, new LibActionStorage.TransactionRecord[](0));
        }

        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new LibActionStorage.TransactionRecord[](end - pageOffset);

        uint256 seen;
        uint256 outIdx;
        for (uint256 i = ids.length; i > 0; i--) {
            uint256 actionId = ids[i - 1];
            if (!_matchByPeriodAndCategory(a.txRecordByActionId[actionId], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                continue;
            }
            if (seen >= pageOffset && seen < end) {
                page[outIdx] = a.txRecordByActionId[actionId];
                outIdx++;
            }
            seen++;
            if (seen >= end) break;
        }
    }

    function _getSubordinateTransactionsByRangePagedFull(
        address subordinate,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 pageOffset,
        uint256 pageLimit,
        bytes32 txCategoryFilter,
        uint8 accountMode
    ) internal view returns (uint256 total, TransactionFull[] memory page) {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256[] storage ids = a.subordinateActionIds[subordinate];

        for (uint256 i = 0; i < ids.length; i++) {
            if (_matchByPeriodAndCategory(a.txRecordByActionId[ids[i]], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                total++;
            }
        }

        if (pageOffset >= total || pageLimit == 0) {
            return (total, new TransactionFull[](0));
        }

        uint256 end = pageOffset + pageLimit;
        if (end > total) end = total;
        page = new TransactionFull[](end - pageOffset);

        uint256 seen;
        uint256 outIdx;
        for (uint256 i = ids.length; i > 0; i--) {
            uint256 actionId = ids[i - 1];
            if (!_matchByPeriodAndCategory(a.txRecordByActionId[actionId], periodStart, periodEnd, txCategoryFilter, accountMode)) {
                continue;
            }
            if (seen >= pageOffset && seen < end) {
                page[outIdx] = _buildFullTransaction(a.txRecordByActionId[actionId], a.routeByActionId[actionId]);
                outIdx++;
            }
            seen++;
            if (seen >= end) break;
        }
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

    function _isValidAccountMode(uint8 accountMode) internal pure returns (bool) {
        return accountMode == ACCOUNT_MODE_ALL || accountMode == ACCOUNT_MODE_EOA || accountMode == ACCOUNT_MODE_AA;
    }

    function _isValidGasChainTypeFilter(uint16 gasChainTypeFilter) internal pure returns (bool) {
        return gasChainTypeFilter == GAS_CHAIN_FILTER_ALL || gasChainTypeFilter <= uint16(LibActionStorage.GasChainType.SOLANA);
    }

    function _isValidChainIdFilter(uint256 chainIdFilter) internal pure returns (bool) {
        return chainIdFilter == CHAIN_ID_FILTER_ALL || chainIdFilter > 0;
    }

    function _shiftPeriodStartBack(uint256 startTs, uint8 periodType, uint256 periodOffset) internal pure returns (uint256) {
        if (periodOffset == 0) return startTs;

        if (periodType == PERIOD_HOUR) return startTs - (periodOffset * 1 hours);
        if (periodType == PERIOD_DAY) return startTs - (periodOffset * 1 days);
        if (periodType == PERIOD_WEEK) return startTs - (periodOffset * 7 days);

        uint256 s = startTs;
        for (uint256 i = 0; i < periodOffset; i++) {
            s = _previousPeriodStart(s, periodType);
        }
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

    function _isValidActionPeriodType(uint8 periodType) internal pure returns (bool) {
        return
            periodType == PERIOD_HOUR ||
            periodType == PERIOD_DAY ||
            periodType == PERIOD_WEEK ||
            periodType == PERIOD_MONTH ||
            periodType == PERIOD_QUARTER ||
            periodType == PERIOD_YEAR;
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

    function _requireActionExists(uint256 actionId) internal view {
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        require(actionId < a.txCount, "invalid actionId");
        require(a.txRecordByActionId[actionId].exists, "tx not found");
    }

    /// @notice 一次性 backfill：把范围 [fromActionId, toActionId) 内 subordinate 不为 0 且不等于 payer/payee
    /// 的 actionId 追加到 accountActionIds[subordinate]，使 `getAccountTransactionsPaged(POS_EOA)`
    /// 能直接返回 POS 终端经手的全部历史记录。
    ///
    /// - 仅 Diamond owner 可调用（与 AdminFacet/setAdmin 同等权限源）
    /// - 单次最多 500 条，超出会 revert，调用方自行分批
    /// - 用 ActionFacet 私有 slot 的 `done[actionId]` 做幂等保护，重复调用不会重复 push
    /// - 事件 `SubordinateAccountIndexBackfilled(from,to,pushed)` 便于离线核对
    function backfillSubordinateIntoAccountIndex(uint256 fromActionId, uint256 toActionId)
        external
        returns (uint256 pushed)
    {
        LibDiamond.enforceIsContractOwner();
        LibActionStorage.Layout storage a = LibActionStorage.layout();
        uint256 total = a.txCount;
        if (toActionId > total) toActionId = total;
        require(fromActionId < toActionId, "empty range");
        require(toActionId - fromActionId <= 500, "range too large");

        SubordinateBackfillStorage storage bf = _subordinateBackfillStorage();
        for (uint256 id = fromActionId; id < toActionId; ++id) {
            if (bf.done[id]) continue;
            bf.done[id] = true;
            LibActionStorage.TransactionRecord storage txr = a.txRecordByActionId[id];
            if (!txr.exists) continue;
            address sub = txr.subordinate;
            if (sub == address(0)) continue;
            if (sub == txr.payer) continue;
            if (sub == txr.payee) continue;
            a.accountActionIds[sub].push(id);
            unchecked { ++pushed; }
        }
        emit SubordinateAccountIndexBackfilled(fromActionId, toActionId, pushed);
    }

    /// @notice 查询某个 actionId 是否已经被 `backfillSubordinateIntoAccountIndex` 处理过（幂等保护）。
    function isSubordinateAccountIndexBackfilled(uint256 actionId) external view returns (bool) {
        return _subordinateBackfillStorage().done[actionId];
    }
}
