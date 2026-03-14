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

    function _getAllAdmins() internal view returns (address[] memory) {
        address[] storage list = GovernanceStorage.layout().adminList;
        address[] memory result = new address[](list.length);
        for (uint256 i = 0; i < list.length; i++) result[i] = list[i];
        return result;
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
