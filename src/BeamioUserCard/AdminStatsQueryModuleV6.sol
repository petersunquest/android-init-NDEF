// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KycLinkOps.sol";

interface IAdminStatsSelectorRouter {
    function selectorModuleKind(bytes4 sel) external view returns (uint8);
}

/**
 * @title BeamioUserCardAdminStatsQueryModuleV6
 * @notice EIP-170-safe **router**: Referrer Registry reads → `referrerViews`;
 *         everything else → existing AdminStats V5 (membership fee, etc.).
 * @dev Card always `delegatecall`s `defaultAdminStatsQueryModule`. This router
 *      re-`delegatecall`s the correct impl so storage context stays the card.
 *      Closes V4/V5 gap where ShareReferee writes landed but read views were
 *      never routed → BM_CallFailed.
 */
contract BeamioUserCardAdminStatsQueryModuleV6 {
    uint8 private constant ROUTE_REDEEM = 0;
    uint8 private constant ROUTE_STATS_QUERY = type(uint8).max - 1;
    uint8 private constant ROUTE_CHARGE_REWARD = 5;

    address public immutable v5;
    address public immutable referrerViews;

    error ZeroImpl();

    constructor(address v5_, address referrerViews_) {
        if (v5_ == address(0) || referrerViews_ == address(0)) revert ZeroImpl();
        v5 = v5_;
        referrerViews = referrerViews_;
    }

    function selectorModuleKind(bytes4 sel) external view returns (uint8) {
        if (_isReferrerRegistryView(sel)) return ROUTE_STATS_QUERY;
        if (_isGovernance(sel)) return 3;
        // Live V5 may predate Unified #13 / topupActor routes — hardcode here.
        if (_isChargeRewardUnified13(sel)) return ROUTE_CHARGE_REWARD;
        // Live V5 may predate Discover Gift redeem — hardcode ROUTE_REDEEM here.
        if (_isGiftRedeem(sel)) return ROUTE_REDEEM;
        if (_isKycLink(sel)) return ROUTE_STATS_QUERY;
        return IAdminStatsSelectorRouter(v5).selectorModuleKind(sel);
    }

    function kycIpfsHashOf(address wallet) external view returns (bytes32) {
        return KycLinkOps.kycIpfsHashOf(wallet);
    }

    function kycPolicy() external view returns (bool required, uint8 nameMode, uint8 phoneMode, uint8 emailMode) {
        return KycLinkOps.kycPolicy();
    }

    function setKycPolicy(bool required, uint8 nameMode, uint8 phoneMode, uint8 emailMode) external {
        KycLinkOps.setKycPolicy(required, nameMode, phoneMode, emailMode);
    }

    function linkKycIpfsHashWithSignature(
        address wallet,
        bytes32 ipfsHash,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external {
        KycLinkOps.linkKycIpfsHashWithSignature(wallet, ipfsHash, deadline, nonce, signature);
    }

    function linkKycIpfsHashByAdmin(
        address wallet,
        bytes32 ipfsHash,
        uint256 deadline,
        uint256 nonce,
        bytes calldata adminSignature
    ) external {
        KycLinkOps.linkKycIpfsHashByAdmin(wallet, ipfsHash, deadline, nonce, adminSignature);
    }

    function _isKycLink(bytes4 sel) private pure returns (bool) {
        return sel == 0x032a78db
            || sel == 0x85ca2bb9
            || sel == 0x60ad4139
            || sel == 0xd1d93203
            || sel == bytes4(keccak256("linkKycIpfsHashByAdmin(address,bytes32,uint256,uint256,bytes)"));
    }

    function _isGovernance(bytes4 sel) private pure returns (bool) {
        return sel == bytes4(keccak256("adminManager(address,bool,uint256,string)"))
            || sel == bytes4(keccak256("adminManager(address,bool,uint256,string,uint256)"))
            || sel == bytes4(keccak256("adminManagerBatch(address[],uint256,string,uint256)"))
            || sel == bytes4(keccak256("adminManagerByAdmin(address,bool,uint256,string,address)"))
            || sel == bytes4(keccak256("adminManagerByAdmin(address,bool,uint256,string,address,uint256)"))
            || sel == bytes4(keccak256("setAdminAirdropLimit(address,uint256)"))
            || sel == bytes4(keccak256("setAdminAirdropLimitByAdmin(address,uint256,address)"));
    }

    function _isGiftRedeem(bytes4 sel) private pure returns (bool) {
        return sel == bytes4(keccak256("createGiftRedeemForPayer(bytes32,uint256,uint256,uint64,uint64)"))
            || sel == bytes4(keccak256("createGiftRedeemWithCreditBurn(bytes32,uint256,uint256,uint256,address,uint64,uint64)"))
            || sel == bytes4(keccak256("createGiftRedeemWithReward13Payment(bytes32,uint256,uint256,uint256,uint256,address,address,uint64,uint64,uint256,bytes32,bytes32)"))
            || sel == bytes4(keccak256("getGiftRedeemSplit(bytes32)"));
    }

    function _isReferrerRegistryView(bytes4 sel) private pure returns (bool) {
        return sel == bytes4(keccak256("referrerTotalCount()"))
            || sel == bytes4(keccak256("registeredRefereeTotalCount()"))
            || sel == bytes4(keccak256("refereeCountByReferrer(address)"))
            || sel == bytes4(keccak256("getReferrersPage(uint256,uint256)"))
            || sel == bytes4(keccak256("getRefereesByReferrerPage(address,uint256,uint256)"))
            || sel == bytes4(keccak256("getRegisteredRefereesPage(uint256,uint256)"))
            || sel == bytes4(keccak256("refereeReferrer(address)"))
            || sel == bytes4(keccak256("refereeChargePointsTotal6(address)"))
            || sel == bytes4(keccak256("getReferrerRefereeLedger(address,address)"));
    }

    function _isChargeRewardUnified13(bytes4 sel) private pure returns (bool) {
        return sel == bytes4(keccak256("topupActorRewardRatioE6()"))
            || sel == bytes4(keccak256("topupPromotionBonusRatioE6()"))
            || sel == bytes4(keccak256("setTopupActorRewardRatio(uint256)"))
            || sel == bytes4(keccak256("setTopupActorRewardRatioByAdmin(uint256)"))
            || sel == bytes4(keccak256("setTopupPromotionBonusRatio(uint256)"))
            || sel == bytes4(keccak256("setTopupPromotionBonusRatioByAdmin(uint256)"))
            || sel == bytes4(keccak256("topupReward(uint256,uint256)"))
            || sel == bytes4(keccak256("topupReward(uint256,uint256,uint256)"))
            || sel == bytes4(keccak256("chargeReward(uint256,uint256)"))
            || sel == bytes4(keccak256("recordTopupCumulativeStat(address,uint256)"))
            || sel == bytes4(keccak256("recordChargeReferrerReward(address,uint256)"))
            || sel == bytes4(keccak256("convertReward13ToPointsRatioE6()"))
            || sel == bytes4(keccak256("convertReward13ToUsdcRatioE6()"))
            || sel == bytes4(keccak256("merchantOracleSpreadBps()"))
            || sel == bytes4(keccak256("quoteUsdcDepositForFiat6(uint256)"))
            || sel == bytes4(keccak256("quoteUsdcWithdrawForFiat6(uint256)"))
            || sel == bytes4(keccak256("applyDepositSpreadUsdc6(uint256)"))
            || sel == bytes4(keccak256("applyWithdrawSpreadUsdc6(uint256)"))
            || sel == bytes4(keccak256("setConvertReward13ToPointsRatio(uint256)"))
            || sel == bytes4(keccak256("setConvertReward13ToPointsRatioByAdmin(uint256)"))
            || sel == bytes4(keccak256("setConvertReward13ToUsdcRatio(uint256)"))
            || sel == bytes4(keccak256("setConvertReward13ToUsdcRatioByAdmin(uint256)"))
            || sel == bytes4(keccak256("setMerchantOracleSpreadBps(uint256)"))
            || sel == bytes4(keccak256("setMerchantOracleSpreadBpsByAdmin(uint256)"))
            || sel == bytes4(keccak256("convertReward13ToProgramPoints(address,uint256)"))
            || sel == bytes4(keccak256("convertReward13ToUsdcToAa(address,uint256)"))
            || sel == bytes4(keccak256("peerRedeem13ForContainerTopup(address,uint256,uint256,address)"))
            || sel == bytes4(keccak256("topupWithReward13Container(address,uint256,uint256,uint256,uint256,uint256,bytes32)"));
    }

    fallback() external payable {
        address target = _isReferrerRegistryView(msg.sig) ? referrerViews : v5;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {
        revert();
    }
}
