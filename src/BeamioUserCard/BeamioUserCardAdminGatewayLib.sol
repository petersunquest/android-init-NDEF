// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./IBeamioUserCardSelfDelegate.sol";

/// @dev Owner/gateway admin maintenance entrypoints routed through modules.
library BeamioUserCardAdminGatewayLib {
    uint8 internal constant MODULE_GOVERNANCE = BeamioUserCardModuleKinds.GOVERNANCE;

    function clearAdminMintCounterForSubordinate(
        IBeamioUserCardSelfDelegate delegate,
        address subordinate,
        address authorizer
    ) external {
        delegate.cardSelfCallModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(
                IBeamioGovernanceModuleV1.clearAdminStatsAndAirdropUsageForSubordinate.selector,
                subordinate,
                authorizer
            )
        );
    }

    function resetAdminLimit(IBeamioUserCardSelfDelegate delegate, address adminAddr) external {
        delegate.cardSelfCallModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.resetAdminLimit.selector, adminAddr)
        );
    }

    function resetAdminLimitByAdmin(IBeamioUserCardSelfDelegate delegate, address adminAddr, address authorizer)
        external
    {
        delegate.cardSelfCallModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.resetAdminLimitByAdmin.selector, adminAddr, authorizer)
        );
    }
}
