// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";

/// @dev Module resolution + fallback delegatecall routing.
///      Uses per-module Factory getters (live Factory has no defaultModule(uint8)).
library BeamioUserCardModuleRouterLib {
    uint8 internal constant ROUTE_STATS_QUERY = BeamioUserCardModuleKinds.STATS_QUERY;
    uint8 internal constant MODULE_REDEEM = BeamioUserCardModuleKinds.REDEEM;
    uint8 internal constant MODULE_GOVERNANCE = BeamioUserCardModuleKinds.GOVERNANCE;
    uint8 internal constant MODULE_FAUCET = BeamioUserCardModuleKinds.FAUCET;
    uint8 internal constant MODULE_ISSUED_NFT = BeamioUserCardModuleKinds.ISSUED_NFT;
    uint8 internal constant MODULE_MEMBERSHIP_STATS = BeamioUserCardModuleKinds.MEMBERSHIP_STATS;
    uint8 internal constant MODULE_CHARGE_REWARD = BeamioUserCardModuleKinds.CHARGE_REWARD;

    function module(address gw, uint8 moduleKind) public view returns (address) {
        if (gw == address(0) || gw.code.length == 0) revert UC_GlobalMisconfigured();
        IBeamioUserCardFactoryPaymasterV07 f = IBeamioUserCardFactoryPaymasterV07(gw);
        address m;
        if (moduleKind == MODULE_REDEEM) m = f.defaultRedeemModule();
        else if (moduleKind == MODULE_FAUCET) m = f.defaultFaucetModule();
        else if (moduleKind == MODULE_ISSUED_NFT) m = f.defaultIssuedNftModule();
        else if (moduleKind == MODULE_GOVERNANCE) m = f.defaultGovernanceModule();
        else if (moduleKind == MODULE_MEMBERSHIP_STATS) m = f.defaultMembershipStatsModule();
        else if (moduleKind == MODULE_CHARGE_REWARD) m = f.defaultChargeRewardModule();
        else revert BM_CallFailed();
        if (m != address(0)) return m;
        if (moduleKind == MODULE_MEMBERSHIP_STATS) revert UC_StatsModuleZero();
        revert UC_RedeemModuleZero();
    }

    function statsQueryModule(address gw) public view returns (address) {
        if (gw == address(0) || gw.code.length == 0) revert UC_GlobalMisconfigured();
        address m = IBeamioUserCardFactoryPaymasterV07(gw).defaultAdminStatsQueryModule();
        if (m == address(0) || m.code.length == 0) revert UC_GlobalMisconfigured();
        return m;
    }

    function resolveFallbackModule(address gw, bytes4 sig) public view returns (address) {
        address statsModule = statsQueryModule(gw);
        uint8 route = IBeamioUserCardSelectorRouter(statsModule).selectorModuleKind(sig);
        // Match prior card fallback routes (MembershipStats was not in legacy fallback).
        if (route == ROUTE_STATS_QUERY) return statsModule;
        if (route == MODULE_REDEEM) return module(gw, MODULE_REDEEM);
        if (route == MODULE_GOVERNANCE) return module(gw, MODULE_GOVERNANCE);
        if (route == MODULE_FAUCET) return module(gw, MODULE_FAUCET);
        if (route == MODULE_ISSUED_NFT) return module(gw, MODULE_ISSUED_NFT);
        if (route == MODULE_CHARGE_REWARD) return module(gw, MODULE_CHARGE_REWARD);
        revert BM_CallFailed();
    }

    function delegateFallback(address targetModule) internal {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), targetModule, 0, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(0, 0, size)
            switch ok
            case 0 { revert(0, size) }
            default { return(0, size) }
        }
    }
}
