// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AdminStatsQueryModule.sol";

/**
 * @title BeamioUserCardAdminStatsQueryModuleV2
 * @notice Routes new kind-2 / kind-5 cumulative + reward pool selectors.
 */
contract BeamioUserCardAdminStatsQueryModuleV2 is BeamioUserCardAdminStatsQueryModuleV1 {
    uint8 private constant ROUTE_ISSUED_NFT = 2;
    uint8 private constant ROUTE_CHARGE_REWARD = 5;
    uint8 private constant ROUTE_INVALID = type(uint8).max;

    function selectorModuleKind(bytes4 sel) public pure virtual override returns (uint8) {
        uint8 v2 = _selectorModuleKindV2(sel);
        if (v2 != ROUTE_INVALID) return v2;
        return super._selectorModuleKindV1(sel);
    }

    function _selectorModuleKindV2(bytes4 sel) private pure returns (uint8) {
        if (
            sel == bytes4(keccak256("initializeCardUserCumulativeStatTokens()"))
                || sel == bytes4(keccak256("cardUserCumulativeStatTokensInitialized()"))
                || sel == bytes4(keccak256("recordUserCumulativeStat(address,uint8,uint8,uint256,uint256)"))
                || sel == bytes4(keccak256("burnUserCumulativeStatByGateway(address,uint8,uint8,uint256,uint256)"))
                || sel == bytes4(keccak256("resolveUserCumulativeStatTokenId(uint8,uint8,uint256)"))
                || sel == bytes4(keccak256("bootstrapIssuedNftV2StatTokens(uint256)"))
                || sel == bytes4(keccak256("applyUserLikeWithSignature(address,uint8,uint256,bool,uint256,bytes32,bytes)"))
                || sel
                    == bytes4(
                        keccak256(
                            "claimSocialExchangeWithUserSignature(address,uint256,uint256,uint256,uint256,bytes32,bytes)"
                        )
                    )
                || sel == bytes4(keccak256("validateAndRecordSocialExchangeUsdcClaim(address,uint256)"))
        ) {
            return ROUTE_ISSUED_NFT;
        }
        if (
            sel == bytes4(keccak256("REWARD_VOUCHER_TOKEN_ID()"))
                || sel == bytes4(keccak256("rewardMintBudget13()"))
                || sel == bytes4(keccak256("rewardEscrowUsdc6()"))
                || sel == bytes4(keccak256("rewardEscrowPoints6()"))
                || sel == bytes4(keccak256("getRewardRule(uint256)"))
                || sel == bytes4(keccak256("configureEventRewardRule(uint256,bool,uint8,uint8,uint256,uint256,uint256)"))
                || sel == bytes4(keccak256("purchaseRewardProgram(address,uint8,uint256,uint256,uint8,uint256)"))
                || sel == bytes4(keccak256("dispatchEventReward13(uint256,address,address,uint8,uint256,uint256)"))
                || sel == bytes4(keccak256("recordTopupCumulativeStat(address,uint256)"))
                || sel == bytes4(keccak256("setBunitAirdropCaller(address)"))
                || sel == bytes4(keccak256("bunitAirdropCaller()"))
                || sel == bytes4(keccak256("recordBUnitInstallAttribution(address,address,uint8,uint256)"))
                || sel == bytes4(keccak256("fundSocialExchangeUsdcEscrow(address,uint256)"))
                || sel == bytes4(keccak256("burnSocialPointsFromUserForExchange(address,uint256)"))
                || sel == bytes4(keccak256("payoutSocialExchangeUsdcToUser(address,uint256)"))
        ) {
            return ROUTE_CHARGE_REWARD;
        }
        return ROUTE_INVALID;
    }
}
