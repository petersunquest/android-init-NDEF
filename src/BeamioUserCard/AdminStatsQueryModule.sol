// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AdminStatsPeriodLib.sol";
import "./AdminStatsStorage.sol";
import "./GovernanceStorage.sol";

interface IUserCardCtx {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
}

contract BeamioUserCardAdminStatsQueryModuleV1 {
    uint8 private constant ROUTE_INVALID = type(uint8).max;
    uint8 private constant ROUTE_STATS_QUERY = type(uint8).max - 1;
    uint8 private constant ROUTE_REDEEM = 0;
    uint8 private constant ROUTE_FAUCET = 1;
    uint8 private constant ROUTE_ISSUED_NFT = 2;
    uint8 private constant ROUTE_GOVERNANCE = 3;

    struct AdminAirdropLimitView {
        address admin;
        address parent;
        uint256 limit;
        uint256 usedFromClear;
        uint256 remainingAvailable;
        bool unlimited;
    }

    struct AdminAirdropLimitNodeView {
        AdminAirdropLimitView self;
        address[] subordinateAdmins;
        uint256 subordinateTotal;
    }

    struct AdminAirdropLimitPageView {
        address queryTarget;
        uint256 adminOffset;
        uint256 adminPageSize;
        uint256 adminTotal;
        uint256 subordinateOffset;
        uint256 subordinatePageSize;
        AdminAirdropLimitNodeView[] admins;
    }

    struct AdminStatsFullView {
        uint256 cumulativeMint;
        uint256 cumulativeBurn;
        uint256 cumulativeTransfer;
        uint256 cumulativeTransferAmount;
        uint256 cumulativeRedeemMint;
        uint256 cumulativeUSDCMint;
        uint256 cumulativeIssued;
        uint256 cumulativeUpgraded;
        uint256 periodMint;
        uint256 periodBurn;
        uint256 periodTransfer;
        uint256 periodTransferAmount;
        uint256 periodRedeemMint;
        uint256 periodUSDCMint;
        uint256 periodIssued;
        uint256 periodUpgraded;
        uint256 mintCounterFromClear;
        uint256 burnCounterFromClear;
        uint256 transferCounterFromClear;
        uint256 transferAmountFromClear;
        uint256 redeemMintCounterFromClear;
        uint256 usdcMintCounterFromClear;
        address[] subordinates;
    }

    struct AdminHourlyDataView {
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

    struct GlobalStatsFullView {
        uint256 cumulativeMint;
        uint256 cumulativeBurn;
        uint256 cumulativeTransfer;
        uint256 cumulativeTransferAmount;
        uint256 cumulativeRedeemMint;
        uint256 cumulativeUSDCMint;
        uint256 cumulativeIssued;
        uint256 cumulativeUpgraded;
        uint256 periodMint;
        uint256 periodBurn;
        uint256 periodTransfer;
        uint256 periodTransferAmount;
        uint256 periodRedeemMint;
        uint256 periodUSDCMint;
        uint256 periodIssued;
        uint256 periodUpgraded;
        uint256 adminCount;
    }

    /// @dev Keep selector classification out of BeamioUserCard runtime so the card stays below EIP-170.
    function selectorModuleKind(bytes4 sel) external pure returns (uint8) {
        if (
            sel == bytes4(keccak256("getAdminHourlyData(address,uint256)"))
                || sel == bytes4(keccak256("getGlobalStatsFull(uint8,uint256,uint256)"))
                || sel == bytes4(keccak256("getAdminStatsFull(address,uint8,uint256,uint256)"))
                || sel == bytes4(keccak256("getAdminPeriodReports(address,uint8,uint256,uint256)"))
                || sel == bytes4(keccak256("getAdminListWithMetadata()"))
                || sel == bytes4(keccak256("getAdminSubordinatesWithMetadata(address)"))
                || sel == bytes4(keccak256("getAdminAirdropLimit(address)"))
                || sel == bytes4(keccak256("getAdminAndSubordinateLimits(address)"))
                || sel == bytes4(keccak256("getAdminAndSubordinateLimitsPage(address,uint256,uint256,uint256,uint256)"))
        ) return ROUTE_STATS_QUERY;

        if (
            sel == bytes4(keccak256("createRedeemAdmin(bytes32,string,uint64,uint64)"))
                || sel == bytes4(keccak256("createRedeemAdmin(bytes32,string,uint64,uint64,uint256)"))
                || sel == bytes4(keccak256("createRedeem(bytes32,uint256,uint256,uint64,uint64,uint256[],uint256[])"))
                || sel == bytes4(keccak256("createRedeem(bytes32,uint256,uint256,uint64,uint64,uint256[],uint256[],address)"))
                || sel == bytes4(keccak256("createRedeemWithCreator(bytes32,uint256,uint256,uint64,uint64,uint256[],uint256[],address)"))
                || sel == bytes4(keccak256("createRedeemWithCreatorAndRecommender(bytes32,uint256,uint256,uint64,uint64,uint256[],uint256[],address,address)"))
                || sel == bytes4(keccak256("createRedeemBatch(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[])"))
                || sel == bytes4(keccak256("createRedeemBatch(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[],address)"))
                || sel == bytes4(keccak256("createRedeemBatchWithCreator(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[],address)"))
                || sel == bytes4(keccak256("createRedeemBatchWithCreatorAndRecommender(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[],address,address)"))
                || sel == bytes4(keccak256("getRedeemStatus(bytes32)"))
                || sel == bytes4(keccak256("getRedeemStatusBatch(string[])"))
                || sel == bytes4(keccak256("getRedeemStatusBatch(bytes32[])"))
                || sel == bytes4(keccak256("getRedeemStatusEx(bytes32,address)"))
                || sel == bytes4(keccak256("getRedeemCreator(string)"))
                || sel == bytes4(keccak256("getRedeemRecommender(string)"))
                || sel == bytes4(keccak256("getRedeemAdminStatus(bytes32)"))
                || sel == bytes4(keccak256("getRedeemAdminList()"))
                || sel == bytes4(keccak256("cancelRedeemAdmin(bytes32)"))
                || sel == bytes4(keccak256("cancelRedeem(string)"))
                || sel == bytes4(keccak256("createRedeemPool(bytes32,uint64,uint64,uint256[][],uint256[][],uint32[])"))
                || sel == bytes4(keccak256("createRedeemPool(bytes32,uint64,uint64,uint256[][],uint256[][],uint32[],address)"))
                || sel == bytes4(keccak256("createRedeemPoolWithCreator(bytes32,uint64,uint64,uint256[][],uint256[][],uint32[],address)"))
                || sel == bytes4(keccak256("createRedeemPoolWithCreatorAndRecommender(bytes32,uint64,uint64,uint256[][],uint256[][],uint32[],address,address)"))
                || sel == bytes4(keccak256("terminateRedeemPool(bytes32)"))
        ) return ROUTE_REDEEM;

        if (
            sel == bytes4(keccak256("adminManager(address,bool,uint256,string)"))
                || sel == bytes4(keccak256("adminManager(address,bool,uint256,string,uint256)"))
                || sel == bytes4(keccak256("adminManagerByAdmin(address,bool,uint256,string,address)"))
                || sel == bytes4(keccak256("adminManagerByAdmin(address,bool,uint256,string,address,uint256)"))
                || sel == bytes4(keccak256("setAdminAirdropLimit(address,uint256)"))
                || sel == bytes4(keccak256("setAdminAirdropLimitByAdmin(address,uint256,address)"))
        ) return ROUTE_GOVERNANCE;

        if (sel == bytes4(keccak256("setFaucetConfig(uint256,uint64,uint64,uint128,uint128,bool,uint8,uint128)"))) {
            return ROUTE_FAUCET;
        }
        if (sel == bytes4(keccak256("createIssuedNft(bytes32,uint64,uint64,uint256,uint256,bytes32)"))) {
            return ROUTE_ISSUED_NFT;
        }
        return ROUTE_INVALID;
    }

    struct AdminPeriodReportsView {
        uint256[] periodStarts;
        uint256[] periodEnds;
        uint256[] totalNftMinteds;
        uint256[] totalTokenMinteds;
        uint256[] totalTokenBurneds;
        uint256[] totalTransferss;
        uint256[] totalTransferAmounts;
        uint256[] totalRedeemMints;
        uint256[] totalUSDCMints;
        uint256[] totalIssueds;
        uint256[] totalUpgradeds;
        uint256 adminMintCounter;
    }

    function getAdminHourlyData(address admin, uint256 hourIndex) external view returns (AdminHourlyDataView memory result) {
        AdminStatsStorage.HourlyStats storage h = AdminStatsStorage.layout().adminHourlyData[admin][hourIndex];
        result.nftMinted = h.nftMinted;
        result.tokenMinted = h.tokenMinted;
        result.tokenBurned = h.tokenBurned;
        result.transferCount = h.transferCount;
        result.transferAmount = h.transferAmount;
        result.redeemMintAmount = h.redeemMintAmount;
        result.usdcMintAmount = h.usdcMintAmount;
        result.issuedCount = h.issuedCount;
        result.upgradedCount = h.upgradedCount;
        result.hasData = h.hasData;
    }

    function getGlobalStatsFull(uint8 periodType, uint256 anchorTs, uint256 cumulativeStartTs)
        external
        view
        returns (GlobalStatsFullView memory result)
    {
        address[] memory admins = _getAllAdmins();
        AdminStatsPeriodLib.GlobalStatsFullResult memory r = AdminStatsPeriodLib.getGlobalStatsFull(
            AdminStatsStorage.layout(),
            admins,
            periodType,
            anchorTs,
            cumulativeStartTs
        );
        result.cumulativeMint = r.cumulativeMint;
        result.cumulativeBurn = r.cumulativeBurn;
        result.cumulativeTransfer = r.cumulativeTransfer;
        result.cumulativeTransferAmount = r.cumulativeTransferAmount;
        result.cumulativeRedeemMint = r.cumulativeRedeemMint;
        result.cumulativeUSDCMint = r.cumulativeUSDCMint;
        result.cumulativeIssued = r.cumulativeIssued;
        result.cumulativeUpgraded = r.cumulativeUpgraded;
        result.periodMint = r.periodMint;
        result.periodBurn = r.periodBurn;
        result.periodTransfer = r.periodTransfer;
        result.periodTransferAmount = r.periodTransferAmount;
        result.periodRedeemMint = r.periodRedeemMint;
        result.periodUSDCMint = r.periodUSDCMint;
        result.periodIssued = r.periodIssued;
        result.periodUpgraded = r.periodUpgraded;
        result.adminCount = r.adminCount;
    }

    function getAdminStatsFull(address admin, uint8 periodType, uint256 anchorTs, uint256 cumulativeStartTs)
        external
        view
        returns (AdminStatsFullView memory result)
    {
        address[] memory admins = _getSelfAndSubordinates(admin);
        AdminStatsPeriodLib.AdminStatsFullResult memory r = AdminStatsPeriodLib.getAdminStatsFull(
            AdminStatsStorage.layout(),
            admins,
            periodType,
            anchorTs,
            cumulativeStartTs
        );
        result.cumulativeMint = r.cumulativeMint;
        result.cumulativeBurn = r.cumulativeBurn;
        result.cumulativeTransfer = r.cumulativeTransfer;
        result.cumulativeTransferAmount = r.cumulativeTransferAmount;
        result.cumulativeRedeemMint = r.cumulativeRedeemMint;
        result.cumulativeUSDCMint = r.cumulativeUSDCMint;
        result.cumulativeIssued = r.cumulativeIssued;
        result.cumulativeUpgraded = r.cumulativeUpgraded;
        result.periodMint = r.periodMint;
        result.periodBurn = r.periodBurn;
        result.periodTransfer = r.periodTransfer;
        result.periodTransferAmount = r.periodTransferAmount;
        result.periodRedeemMint = r.periodRedeemMint;
        result.periodUSDCMint = r.periodUSDCMint;
        result.periodIssued = r.periodIssued;
        result.periodUpgraded = r.periodUpgraded;
        result.mintCounterFromClear = r.mintCounterFromClear;
        result.burnCounterFromClear = r.burnCounterFromClear;
        result.transferCounterFromClear = r.transferCounterFromClear;
        result.transferAmountFromClear = r.transferAmountFromClear;
        result.redeemMintCounterFromClear = r.redeemMintCounterFromClear;
        result.usdcMintCounterFromClear = r.usdcMintCounterFromClear;
        result.subordinates = r.subordinates;
    }

    function getAdminPeriodReports(address admin, uint8 periodType, uint256 periods, uint256 anchorTs)
        external
        view
        returns (AdminPeriodReportsView memory result)
    {
        AdminStatsPeriodLib.AdminPeriodReportsResult memory r =
            AdminStatsPeriodLib.getPeriodReports(AdminStatsStorage.layout(), admin, periodType, periods, anchorTs);
        uint256 n = r.reports.length;
        result.periodStarts = new uint256[](n);
        result.periodEnds = new uint256[](n);
        result.totalNftMinteds = new uint256[](n);
        result.totalTokenMinteds = new uint256[](n);
        result.totalTokenBurneds = new uint256[](n);
        result.totalTransferss = new uint256[](n);
        result.totalTransferAmounts = new uint256[](n);
        result.totalRedeemMints = new uint256[](n);
        result.totalUSDCMints = new uint256[](n);
        result.totalIssueds = new uint256[](n);
        result.totalUpgradeds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            result.periodStarts[i] = r.reports[i].periodStart;
            result.periodEnds[i] = r.reports[i].periodEnd;
            result.totalNftMinteds[i] = r.reports[i].stats.totalNftMinted;
            result.totalTokenMinteds[i] = r.reports[i].stats.totalTokenMinted;
            result.totalTokenBurneds[i] = r.reports[i].stats.totalTokenBurned;
            result.totalTransferss[i] = r.reports[i].stats.totalTransfers;
            result.totalTransferAmounts[i] = r.reports[i].stats.totalTransferAmount;
            result.totalRedeemMints[i] = r.reports[i].stats.totalRedeemMint;
            result.totalUSDCMints[i] = r.reports[i].stats.totalUSDCMint;
            result.totalIssueds[i] = r.reports[i].stats.totalIssued;
            result.totalUpgradeds[i] = r.reports[i].stats.totalUpgraded;
        }
        result.adminMintCounter = r.adminMintCounter;
    }

    /// @notice 返回现有 admin 一览，含 address、metadata、parent
    function getAdminListWithMetadata()
        external
        view
        returns (address[] memory admins, string[] memory metadatas, address[] memory parents)
    {
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        uint256 n = l.adminList.length;
        admins = new address[](n);
        metadatas = new string[](n);
        parents = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            address a = l.adminList[i];
            admins[i] = a;
            metadatas[i] = l.adminMetadata[a];
            parents[i] = l.adminParent[a];
        }
    }

    /// @notice 返回某一 admin 下层的 admin 一览（直接子 admin），含 metadata
    /// @param admin 父 admin 地址；传 address(0) 可查 owner 直接添加的 admin（adminParent==0 且非 owner）
    function getAdminSubordinatesWithMetadata(address admin)
        external
        view
        returns (address[] memory subordinates, string[] memory metadatas, address[] memory parents)
    {
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        address cardOwner = IUserCardCtx(address(this)).owner();
        uint256 n = 0;
        if (admin == address(0)) {
            for (uint256 i = 0; i < l.adminList.length; i++) {
                address a = l.adminList[i];
                if (l.isAdmin[a] && l.adminParent[a] == address(0) && a != cardOwner) n++;
            }
        } else {
            address[] storage children = l.adminChildren[admin];
            for (uint256 i = 0; i < children.length; i++) {
                if (l.isAdmin[children[i]]) n++;
            }
        }
        subordinates = new address[](n);
        metadatas = new string[](n);
        parents = new address[](n);
        uint256 j = 0;
        if (admin == address(0)) {
            for (uint256 i = 0; i < l.adminList.length; i++) {
                address a = l.adminList[i];
                if (l.isAdmin[a] && l.adminParent[a] == address(0) && a != cardOwner) {
                    subordinates[j] = a;
                    metadatas[j] = l.adminMetadata[a];
                    parents[j] = address(0);
                    j++;
                }
            }
        } else {
            address[] storage children = l.adminChildren[admin];
            for (uint256 i = 0; i < children.length; i++) {
                address c = children[i];
                if (l.isAdmin[c]) {
                    subordinates[j] = c;
                    metadatas[j] = l.adminMetadata[c];
                    parents[j] = admin;
                    j++;
                }
            }
        }
    }

    function getAdminAirdropLimit(address admin) external view returns (AdminAirdropLimitView memory result) {
        result = _buildAdminAirdropLimitView(admin);
    }

    function getAdminAndSubordinateLimits(address admin)
        external
        view
        returns (AdminAirdropLimitView memory self, AdminAirdropLimitView[] memory subordinates)
    {
        self = _buildAdminAirdropLimitView(admin);
        address[] memory directSubs = _getDirectSubordinates(admin);
        subordinates = new AdminAirdropLimitView[](directSubs.length);
        for (uint256 i = 0; i < directSubs.length; i++) {
            subordinates[i] = _buildAdminAirdropLimitView(directSubs[i]);
        }
    }

    function getAdminAndSubordinateLimitsPage(
        address to,
        uint256 adminOffset,
        uint256 adminPageSize,
        uint256 subordinateOffset,
        uint256 subordinatePageSize
    ) external view returns (AdminAirdropLimitPageView memory result) {
        address[] memory targets = _getAdminLimitTargets(to);
        uint256 total = targets.length;
        uint256 start = adminOffset > total ? total : adminOffset;
        uint256 end = start + adminPageSize;
        if (end > total) end = total;

        result.queryTarget = to;
        result.adminOffset = start;
        result.adminPageSize = adminPageSize;
        result.adminTotal = total;
        result.subordinateOffset = subordinateOffset;
        result.subordinatePageSize = subordinatePageSize;
        result.admins = new AdminAirdropLimitNodeView[](end - start);

        for (uint256 i = start; i < end; i++) {
            address admin = targets[i];
            uint256 outIndex = i - start;
            result.admins[outIndex].self = _buildAdminAirdropLimitView(admin);
            result.admins[outIndex].subordinateTotal = _countDirectSubordinates(admin);
            result.admins[outIndex].subordinateAdmins = _getDirectSubordinatesPage(
                admin,
                subordinateOffset,
                subordinatePageSize
            );
        }
    }

    function _getAllAdmins() internal view returns (address[] memory) {
        address[] storage list = GovernanceStorage.layout().adminList;
        address[] memory result = new address[](list.length);
        for (uint256 i = 0; i < list.length; i++) result[i] = list[i];
        return result;
    }

    function _buildAdminAirdropLimitView(address admin) internal view returns (AdminAirdropLimitView memory result) {
        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        address cardOwner = IUserCardCtx(address(this)).owner();
        result.admin = admin;
        result.parent = g.adminParent[admin];
        result.usedFromClear = g.adminAirdropUsed[admin];
        result.unlimited = admin == cardOwner;
        result.limit = result.unlimited ? type(uint256).max : g.adminAirdropLimit[admin];
        result.remainingAvailable = result.unlimited
            ? type(uint256).max
            : (result.limit > result.usedFromClear ? result.limit - result.usedFromClear : 0);
    }

    function _getAdminLimitTargets(address to) internal view returns (address[] memory result) {
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        address cardOwner = IUserCardCtx(address(this)).owner();
        if (to == address(0)) {
            return _getDirectSubordinates(cardOwner);
        }
        if (to == cardOwner) {
            result = new address[](1);
            result[0] = cardOwner;
            return result;
        }
        if (!l.isAdmin[to]) {
            return new address[](0);
        }
        result = new address[](1);
        result[0] = to;
    }

    function _countDirectSubordinates(address admin) internal view returns (uint256 total) {
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        address cardOwner = IUserCardCtx(address(this)).owner();
        if (admin == cardOwner || admin == address(0)) {
            for (uint256 i = 0; i < l.adminList.length; i++) {
                address a = l.adminList[i];
                if (l.isAdmin[a] && l.adminParent[a] == address(0) && a != cardOwner) total++;
            }
            return total;
        }

        address[] storage children = l.adminChildren[admin];
        for (uint256 i = 0; i < children.length; i++) {
            if (l.isAdmin[children[i]]) total++;
        }
    }

    function _getDirectSubordinates(address admin) internal view returns (address[] memory result) {
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        address cardOwner = IUserCardCtx(address(this)).owner();
        uint256 n = 0;

        if (admin == cardOwner || admin == address(0)) {
            for (uint256 i = 0; i < l.adminList.length; i++) {
                address a = l.adminList[i];
                if (l.isAdmin[a] && l.adminParent[a] == address(0) && a != cardOwner) n++;
            }

            result = new address[](n);
            uint256 rootIndex = 0;
            for (uint256 i = 0; i < l.adminList.length; i++) {
                address a = l.adminList[i];
                if (l.isAdmin[a] && l.adminParent[a] == address(0) && a != cardOwner) {
                    result[rootIndex++] = a;
                }
            }
            return result;
        }

        address[] storage children = l.adminChildren[admin];
        for (uint256 i = 0; i < children.length; i++) {
            if (l.isAdmin[children[i]]) n++;
        }

        result = new address[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < children.length; i++) {
            address child = children[i];
            if (l.isAdmin[child]) {
                result[j++] = child;
            }
        }
    }

    function _getDirectSubordinatesPage(address admin, uint256 offset, uint256 pageSize)
        internal
        view
        returns (address[] memory result)
    {
        address[] memory all = _getDirectSubordinates(admin);
        uint256 start = offset > all.length ? all.length : offset;
        uint256 end = start + pageSize;
        if (end > all.length) end = all.length;
        result = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = all[i];
        }
    }

    function _getSelfAndSubordinates(address admin) internal view returns (address[] memory) {
        if (admin == address(0) || !GovernanceStorage.layout().isAdmin[admin]) {
            return new address[](0);
        }
        address[] memory out = new address[](64);
        uint256 n = 0;
        out[n++] = admin;
        for (uint256 i = 0; i < n && i < 64; i++) {
            address[] storage children = GovernanceStorage.layout().adminChildren[out[i]];
            for (uint256 j = 0; j < children.length && n < 64; j++) {
                if (GovernanceStorage.layout().isAdmin[children[j]]) {
                    out[n++] = children[j];
                }
            }
        }
        address[] memory result = new address[](n);
        for (uint256 k = 0; k < n; k++) result[k] = out[k];
        return result;
    }
}
